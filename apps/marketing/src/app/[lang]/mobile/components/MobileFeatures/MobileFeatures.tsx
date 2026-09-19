import { Trans } from "@lingui/react/macro";
import type { ReactNode } from "react";
import {
	HiMiniBolt,
	HiMiniChatBubbleLeftRight,
	HiMiniCodeBracketSquare,
} from "react-icons/hi2";

const FEATURES: readonly {
	id: string;
	icon: ReactNode;
	title: ReactNode;
	body: ReactNode;
}[] = [
	{
		id: "start",
		icon: <HiMiniBolt className="size-5" />,
		title: <Trans>Start work from anywhere</Trans>,
		body: (
			<Trans>
				Launch an agent on any connected machine the moment an idea lands. Every
				session gets its own isolated workspace.
			</Trans>
		),
	},
	{
		id: "follow",
		icon: <HiMiniChatBubbleLeftRight className="size-5" />,
		title: <Trans>Follow every session</Trans>,
		body: (
			<Trans>
				Watch agents work in real time and step in with a follow-up, a photo, or
				a dictated message when they need direction.
			</Trans>
		),
	},
	{
		id: "review",
		icon: <HiMiniCodeBracketSquare className="size-5" />,
		title: <Trans>Review before you merge</Trans>,
		body: (
			<Trans>
				Read the full diff file by file, check the PR status, and open a
				terminal when you need the raw output.
			</Trans>
		),
	},
];

export function MobileFeatures() {
	return (
		<section className="grid grid-cols-1 gap-px border border-border bg-border md:grid-cols-3">
			{FEATURES.map((feature) => (
				<article key={feature.id} className="bg-background p-6 sm:p-8">
					<span className="text-brand">{feature.icon}</span>
					<h2 className="mt-4 font-medium text-base text-foreground">
						{feature.title}
					</h2>
					<p className="mt-2 text-muted-foreground text-sm leading-relaxed">
						{feature.body}
					</p>
				</article>
			))}
		</section>
	);
}
