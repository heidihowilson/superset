import type { ReactNode } from "react";

interface PhoneFrameProps {
	children: ReactNode;
	className?: string;
}

export function PhoneFrame({ children, className = "" }: PhoneFrameProps) {
	return (
		<div
			className={`aspect-[9/19] w-[264px] rounded-[44px] border border-white/15 bg-[#1c1c1c] p-[5px] shadow-[0_30px_80px_-20px_rgba(0,0,0,0.8)] ${className}`}
		>
			<div className="relative flex h-full flex-col overflow-hidden rounded-[39px] bg-[#0b0b0b] text-white">
				<div className="flex shrink-0 items-center justify-between px-7 pt-3.5 pb-2">
					<span className="font-semibold text-[11px]">9:41</span>
					<span className="absolute top-2.5 left-1/2 h-[22px] w-[78px] -translate-x-1/2 rounded-full bg-black" />
					<span className="flex items-center gap-1">
						<span className="h-[7px] w-[11px] rounded-[2px] bg-white/80" />
						<span className="h-[9px] w-[18px] rounded-[3px] border border-white/50 p-px">
							<span className="block h-full w-3/4 rounded-[1.5px] bg-emerald-400" />
						</span>
					</span>
				</div>
				{children}
			</div>
		</div>
	);
}
