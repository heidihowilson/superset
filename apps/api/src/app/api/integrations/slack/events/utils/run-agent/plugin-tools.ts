import {
	type ConnectionContext,
	callTool,
	listTools,
	type ToolDefinition,
	templateScope,
	toolConnections,
} from "@superset/trpc/integrations/plugins";

export interface PluginToolSet {
	context: ConnectionContext;
	tools: ToolDefinition[];
}

export interface PluginTools {
	sets: Map<string, PluginToolSet>;
	/** False when connections could not be listed: absence then means unknown, not unconnected. */
	resolved: boolean;
}

export interface ToolCallResult {
	content?: unknown;
	isError?: boolean;
	structuredContent?: unknown;
	[key: string]: unknown;
}

const TOOL_LIST_TTL_MS = 60 * 60 * 1000;

const toolListCache = new Map<
	string,
	{ tools: ToolDefinition[]; expiresAt: number }
>();

export function invalidatePluginToolCache(): void {
	toolListCache.clear();
}

/** Per installation: the same plugin from two marketplaces can list different tools. */
function cacheKey({ connection, install }: ConnectionContext): string {
	return `${install.id}:${install.marketplace}/${connection.pluginName}@${install.manifest.version}:${connection.authMethod}`;
}

async function cachedListTools(
	context: ConnectionContext,
	signal: AbortSignal,
): Promise<ToolDefinition[]> {
	const key = cacheKey(context);
	const cached = toolListCache.get(key);
	if (cached && cached.expiresAt > Date.now()) return cached.tools;

	const tools = await listTools(
		context.install.manifest,
		await templateScope(context.connection),
		context.connection.authMethod,
		context.source,
		{ signal },
	);
	toolListCache.set(key, { tools, expiresAt: Date.now() + TOOL_LIST_TTL_MS });
	return tools;
}

/** The newest connection wins when a user holds several for one plugin. */
export async function loadPluginTools({
	userId,
	pluginNames,
	signal,
}: {
	userId: string;
	pluginNames: Iterable<string>;
	signal: AbortSignal;
}): Promise<PluginTools> {
	const wanted = new Set(pluginNames);
	const byPlugin = new Map<string, ConnectionContext>();
	let contexts: ConnectionContext[];
	try {
		contexts = await toolConnections(userId);
	} catch (error) {
		console.warn("[slack-agent] Skipping plugin tools this run:", error);
		return { sets: new Map(), resolved: false };
	}
	for (const context of contexts) {
		const name = context.connection.pluginName;
		if (wanted.has(name) && !byPlugin.has(name)) byPlugin.set(name, context);
	}

	const sets = new Map<string, PluginToolSet>();
	await Promise.all(
		[...byPlugin.values()].map(async (context) => {
			const name = context.connection.pluginName;
			try {
				sets.set(name, {
					context,
					tools: await cachedListTools(context, signal),
				});
			} catch (error) {
				console.warn(`[slack-agent] Skipping ${name} tools:`, error);
				sets.set(name, { context, tools: [] });
			}
		}),
	);
	return { sets, resolved: true };
}

export async function callPluginTool({
	context,
	tool,
	args,
	signal,
}: {
	context: ConnectionContext;
	tool: string;
	args: Record<string, unknown>;
	signal: AbortSignal;
}): Promise<ToolCallResult> {
	const result = await callTool(
		context.install.manifest,
		await templateScope(context.connection),
		tool,
		args,
		context.connection.authMethod,
		context.source,
		{ signal },
	);
	return (result ?? {}) as ToolCallResult;
}
