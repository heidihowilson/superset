export {
	AmbiguousPluginError,
	type ConnectionContext,
	installedManifest,
	installedPlugin,
	manifestAuth,
	templateScope,
	toolConnections,
	upsertConnection,
} from "../../../router/plugins/connections";
export {
	callTool,
	type DispatchOptions,
	listTools,
	PluginDispatchError,
	type ToolDefinition,
} from "../../../router/plugins/dispatch";
export {
	authMethod,
	DEFAULT_CREDENTIAL_INPUT,
	trustedManifest,
} from "../../../router/plugins/manifest";
export {
	buildAuthorizationUrl,
	exchangeCode,
	resolveIdentity,
} from "../../../router/plugins/oauth";
