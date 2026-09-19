import { COMPANY } from "@superset/shared/constants";
import { renderSVG } from "uqr";

const QR_SVG = renderSVG(COMPANY.APP_STORE_URL, {
	border: 0,
	whiteColor: "transparent",
	blackColor: "#0b0b0b",
});

export function AppStoreQr() {
	return (
		<div
			aria-hidden="true"
			className="hidden size-20 shrink-0 bg-white p-1.5 md:block [&>svg]:size-full"
			// biome-ignore lint/security/noDangerouslySetInnerHtml: SVG generated at module load from a constant URL
			dangerouslySetInnerHTML={{ __html: QR_SVG }}
		/>
	);
}
