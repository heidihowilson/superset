import { PhoneFrame } from "./components/PhoneFrame";
import { ReviewScreen } from "./components/ReviewScreen";
import { SessionScreen } from "./components/SessionScreen";
import { WorkspacesScreen } from "./components/WorkspacesScreen";

const SIDE_PHONE_CLASS =
	"absolute top-10 hidden scale-[0.88] opacity-60 sm:block lg:hidden xl:block";

export function PhoneShowcase() {
	return (
		<div
			aria-hidden="true"
			className="pointer-events-none relative flex select-none justify-center"
		>
			<PhoneFrame
				className={`${SIDE_PHONE_CLASS} right-1/2 origin-right translate-x-[-72px] -rotate-6`}
			>
				<SessionScreen />
			</PhoneFrame>
			<PhoneFrame
				className={`${SIDE_PHONE_CLASS} left-1/2 origin-left translate-x-[72px] rotate-6`}
			>
				<ReviewScreen />
			</PhoneFrame>
			<PhoneFrame className="relative">
				<WorkspacesScreen />
			</PhoneFrame>
		</div>
	);
}
