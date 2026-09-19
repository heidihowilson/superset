import { Trans, useLingui } from "@lingui/react/macro";
import { COMPANY } from "@superset/shared/constants";
import { useRouter } from "expo-router";
import { CloudOff } from "lucide-react-native";
import { View } from "react-native";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Text } from "@/components/ui/text";
import { openUrl } from "@/lib/open-url";

const REMOTE_ACCESS_DOCS_URL = `${COMPANY.DOCS_URL}/remote-access`;

export function HostOfflineView({ hostName }: { hostName: string }) {
	const { t } = useLingui();
	const router = useRouter();
	return (
		<View className="flex-1 items-center justify-center gap-6 px-8">
			<Icon
				as={CloudOff}
				className="text-muted-foreground size-12"
				strokeWidth={1.25}
			/>
			<View className="items-center gap-2">
				<Text className="text-center text-lg font-semibold">
					{t({
						message: `${hostName} is offline`,
					})}
				</Text>
				<View className="items-center gap-3">
					<Text className="text-center text-sm leading-5 text-muted-foreground">
						<Trans>Its workspaces will appear when it reconnects.</Trans>
					</Text>
					<Text className="text-center text-sm leading-5 text-muted-foreground">
						<Trans>
							First time here? Turn on Remote Access in the desktop app under
							Settings → Remote Access.
						</Trans>
					</Text>
				</View>
			</View>
			<View className="items-center gap-1">
				<Button
					variant="secondary"
					onPress={() => router.push("/(authenticated)/(home)/filter/scope")}
				>
					<Text>
						<Trans>Switch host</Trans>
					</Text>
				</Button>
				<Button variant="link" onPress={() => openUrl(REMOTE_ACCESS_DOCS_URL)}>
					<Text>
						<Trans>Set up remote access</Trans>
					</Text>
				</Button>
			</View>
		</View>
	);
}
