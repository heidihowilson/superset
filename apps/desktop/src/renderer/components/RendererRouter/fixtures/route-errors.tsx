import { mock } from "bun:test";
import { transformAsync } from "@babel/core";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import linguiMacro from "@lingui/babel-plugin-lingui-macro";
import { plugin } from "bun";
import type { ReactNode } from "react";

plugin({
	name: "real-lingui-react-macros",
	setup(build) {
		build.onLoad({ filter: /\/(error|not-found)\.tsx$/ }, async ({ path }) => {
			if (path.includes("/node_modules/")) return;
			const code = await Bun.file(path).text();
			if (!/@lingui\/(react|core)\/macro/.test(code)) return;
			const result = await transformAsync(code, {
				filename: path,
				babelrc: false,
				configFile: false,
				parserOpts: { plugins: ["typescript", "jsx"] },
				plugins: [linguiMacro],
			});
			if (!result?.code) throw new Error(`Could not compile ${path}`);
			return { contents: result.code, loader: "tsx" };
		});
	},
});

GlobalRegistrator.register({ url: "http://localhost" });
(
	globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const captured: unknown[] = [];
mock.module("@sentry/electron/renderer", () => ({
	captureException: (error: unknown) => captured.push(error),
}));
const originalError = new Error("Original route failure");
let failLayout = false;
mock.module("../../../routes/-layout", () => ({
	RootLayout: ({ children }: { children: ReactNode }) => {
		if (failLayout) throw originalError;
		return children;
	},
}));

const { act, cleanup, fireEvent, render, waitFor } = await import(
	"@testing-library/react"
);
const { createMemoryHistory, createRoute, createRouter } = await import(
	"@tanstack/react-router"
);
const { QueryClient } = await import("@tanstack/react-query");
const { i18n, initI18nAsync } = await import("@superset/i18n");
const { RendererRouter } = await import("../RendererRouter");
const { Route } = await import("../../../routes/__root");

const home = createRoute({
	getParentRoute: () => Route,
	path: "/",
	component: () => <div data-testid="recovered-home" />,
});
const broken = createRoute({
	getParentRoute: () => Route,
	path: "/broken",
	loader: () => {
		throw originalError;
	},
});
const routeTree = Route.addChildren([home, broken]);
const consoleErrors: unknown[][] = [];
console.error = (...args: unknown[]) => consoleErrors.push(args);
console.warn = () => {};

function check(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

try {
	for (const failure of ["layout", "loader", "not-found"] as const) {
		captured.length = 0;
		consoleErrors.length = 0;
		failLayout = failure === "layout";
		await initI18nAsync("fr");
		const router = createRouter({
			routeTree,
			history: createMemoryHistory({
				initialEntries: [
					failure === "loader"
						? "/broken"
						: failure === "not-found"
							? "/missing"
							: "/",
				],
			}),
			context: { queryClient: new QueryClient() },
		});
		await act(async () => {
			render(<RendererRouter router={router} />);
			await router.load();
		});
		const heading =
			failure === "not-found" ? "Page introuvable" : "Une erreur est survenue";
		await waitFor(() =>
			check(
				document.body.textContent?.includes(heading),
				`${failure}: missing translated fallback`,
			),
		);
		check(i18n.locale === "fr", `${failure}: fallback reset the active locale`);
		if (failure !== "not-found") {
			await waitFor(() =>
				check(
					captured.includes(originalError),
					`${failure}: original error not reported`,
				),
			);
			await act(async () => {
				fireEvent.click(
					document.querySelector(
						"button[aria-controls='error-details']",
					) as Element,
				);
			});
			check(
				document
					.querySelector("pre")
					?.textContent?.includes(originalError.stack ?? originalError.message),
				`${failure}: original error details missing`,
			);
		} else {
			check(captured.length === 0, "404 was reported as a crash");
		}
		check(
			!consoleErrors.some((args) =>
				args.some((arg) => /useLingui|I18nProvider/.test(String(arg))),
			),
			`${failure}: translation context failed`,
		);
		if (failure !== "layout") {
			await act(async () => {
				fireEvent.click(document.querySelector("a") as Element);
			});
			await waitFor(() =>
				check(
					document.querySelector('[data-testid="recovered-home"]'),
					"Go home did not recover",
				),
			);
		}
		cleanup();
	}
	console.log("passed");
} finally {
	cleanup();
	await GlobalRegistrator.unregister();
}
