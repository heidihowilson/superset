import { I18nProvider } from "@lingui/react";
import { i18n, initI18n } from "@superset/i18n";
import { type AnyRouter, RouterProvider } from "@tanstack/react-router";

if (!i18n.locale) initI18n();

export function RendererRouter({ router }: { router: AnyRouter }) {
	return (
		<I18nProvider i18n={i18n}>
			<RouterProvider router={router} />
		</I18nProvider>
	);
}
