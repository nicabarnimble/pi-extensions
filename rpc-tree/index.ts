/**
 * RPC Tree navigation prototype.
 *
 * Adds a `/rpc-tree` extension command that works in RPC mode by using Pi's
 * extension APIs instead of the interactive TUI tree selector.
 *
 * Minimal goals:
 * - `/rpc-tree` shows a simple RPC UI select list when a client supports extension UI.
 * - `/rpc-tree --id <entry-id>` navigates directly, suitable for richer clients such as Emacs.
 * - Non-help invocations emit one machine-readable terminal `rpc-tree:event {...}`
 *   payload; successful navigation includes both targetId and Pi's actual
 *   post-navigation newLeafId.
 * - User/custom-message selections prefill the RPC editor with the selected text,
 *   matching Pi's interactive /tree selection behavior without colliding with it.
 */

import type { ExtensionAPI, ExtensionCommandContext, SessionEntry } from "@earendil-works/pi-coding-agent";

type Entry = SessionEntry;
type TreeNode = { entry: Entry; children?: TreeNode[]; label?: string; labelTimestamp?: string };
type MessageLike = {
	role?: string;
	content?: unknown;
	toolName?: string;
	command?: string;
	stopReason?: string;
};

const UI_TIMEOUT_MS = 60_000;
const RPC_TREE_EVENT_PREFIX = "rpc-tree:event ";
const ARG_COMPLETIONS = [
	"--help",
	"--all",
	"--summary",
	"--no-summary",
	"--custom",
	"--replace-instructions",
	"--id",
	"--label",
];

interface ParsedArgs {
	help: boolean;
	all?: boolean;
	id?: string;
	summarize?: boolean;
	customInstructions?: string;
	replaceInstructions?: boolean;
	label?: string;
}

interface TreeChoice {
	id: string;
	label: string;
}

interface PickerOptions {
	all?: boolean;
}

interface PickerSelection {
	entryId: string;
	parsed: ParsedArgs;
}

interface NavigationEventBase {
	targetId: string;
	targetType?: string;
	oldLeafId: string | null;
	summarize: boolean;
}

type VisibleTreeNode = { node: TreeNode; children: VisibleTreeNode[] };

type ParseResult = { ok: true; value: ParsedArgs } | { ok: false; error: string };

function splitArgs(input: string): string[] {
	const result: string[] = [];
	let current = "";
	let quote: '"' | "'" | null = null;
	let escaping = false;

	for (const ch of input) {
		if (escaping) {
			current += ch;
			escaping = false;
			continue;
		}
		if (ch === "\\") {
			escaping = true;
			continue;
		}
		if (quote) {
			if (ch === quote) quote = null;
			else current += ch;
			continue;
		}
		if (ch === '"' || ch === "'") {
			quote = ch;
			continue;
		}
		if (/\s/.test(ch)) {
			if (current) {
				result.push(current);
				current = "";
			}
			continue;
		}
		current += ch;
	}
	if (escaping) current += "\\";
	if (quote) throw new Error(`Unclosed ${quote} quote`);
	if (current) result.push(current);
	return result;
}

function parseArgs(input: string): ParseResult {
	let tokens: string[];
	try {
		tokens = splitArgs(input.trim());
	} catch (error) {
		return { ok: false, error: error instanceof Error ? error.message : String(error) };
	}

	const parsed: ParsedArgs = { help: false };
	const positional: string[] = [];

	// TODO(rpc-tree): tighten parser semantics for edge cases:
	// - allow flag values that begin with "--" via an explicit `--` terminator or stricter `--flag=value` guidance
	// - reject contradictory summary flags instead of accepting last-wins behavior
	let error: string | undefined;

	const takeValue = (flag: string, index: number): { value?: string; nextIndex: number } => {
		const next = tokens[index + 1];
		if (next === undefined || next.startsWith("--")) {
			error = `${flag} requires a value`;
			return { nextIndex: index };
		}
		return { value: next, nextIndex: index + 1 };
	};

	const setId = (value: string, source: string) => {
		const trimmed = value.trim();
		if (!trimmed) {
			error = `${source} requires a non-empty entry id`;
			return;
		}
		if (parsed.id && parsed.id !== trimmed) {
			error = `Multiple entry ids provided: ${parsed.id} and ${trimmed}`;
			return;
		}
		parsed.id = trimmed;
	};

	for (let i = 0; i < tokens.length && !error; i++) {
		const token = tokens[i];
		if (token === "--help" || token === "-h") parsed.help = true;
		else if (token === "--all") parsed.all = true;
		else if (token === "--id") {
			const { value, nextIndex } = takeValue("--id", i);
			i = nextIndex;
			if (value !== undefined) setId(value, "--id");
		} else if (token.startsWith("--id=")) setId(token.slice("--id=".length), "--id");
		else if (token === "--summary") parsed.summarize = true;
		else if (token === "--no-summary") parsed.summarize = false;
		else if (token === "--custom") {
			const { value, nextIndex } = takeValue("--custom", i);
			i = nextIndex;
			if (value !== undefined) {
				parsed.customInstructions = value;
				parsed.summarize = true;
			}
		} else if (token.startsWith("--custom=")) {
			parsed.customInstructions = token.slice("--custom=".length);
			parsed.summarize = true;
		} else if (token === "--replace-instructions") parsed.replaceInstructions = true;
		else if (token === "--label") {
			const { value, nextIndex } = takeValue("--label", i);
			i = nextIndex;
			if (value !== undefined) parsed.label = value;
		} else if (token.startsWith("--label=")) parsed.label = token.slice("--label=".length);
		else if (token.startsWith("-")) error = `Unknown option: ${token}`;
		else positional.push(token);
	}

	if (error) return { ok: false, error };
	if (positional.length > 1) return { ok: false, error: `Expected at most one entry id, got ${positional.length}` };
	if (positional.length === 1) {
		if (parsed.id) return { ok: false, error: `Unexpected positional entry id: ${positional[0]}` };
		setId(positional[0], "entry id");
		if (error) return { ok: false, error };
	}

	return { ok: true, value: parsed };
}

function truncateOneLine(text: string, max = 96): string {
	const line = text.replace(/\s+/g, " ").trim();
	return line.length <= max ? line : `${line.slice(0, Math.max(0, max - 1))}…`;
}

function textFromContent(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((block): block is { type: "text"; text?: unknown } => {
			return typeof block === "object" && block !== null && (block as { type?: unknown }).type === "text";
		})
		.map((block) => String(block.text ?? ""))
		.join("");
}

function asMessageLike(entry: Entry): MessageLike | undefined {
	return entry.type === "message" ? (entry.message as unknown as MessageLike) : undefined;
}

function entryRole(entry: Entry): string {
	if (entry.type === "message") return asMessageLike(entry)?.role ?? "message";
	if (entry.type === "custom_message") return "custom";
	if (entry.type === "branch_summary") return "branch";
	if (entry.type === "compaction") return "compact";
	if (entry.type === "model_change") return "model";
	if (entry.type === "thinking_level_change") return "think";
	if (entry.type === "label") return "label";
	if (entry.type === "session_info") return "session";
	return entry.type ?? "entry";
}

function entryPreview(entry: Entry): string {
	if (entry.type === "message") {
		const message = asMessageLike(entry);
		const role = message?.role;
		if (role === "user") return truncateOneLine(textFromContent(message?.content));
		if (role === "assistant") return truncateOneLine(textFromContent(message?.content));
		if (role === "toolResult") return truncateOneLine(`${message?.toolName ?? "tool"}: ${textFromContent(message?.content)}`);
		if (role === "bashExecution") return truncateOneLine(`$ ${message?.command ?? ""}`);
		return truncateOneLine(textFromContent(message?.content));
	}
	if (entry.type === "custom_message") return truncateOneLine(textFromContent(entry.content));
	if (entry.type === "branch_summary") return truncateOneLine(entry.summary ?? "branch summary");
	if (entry.type === "compaction") return truncateOneLine(entry.summary ?? "compaction");
	if (entry.type === "model_change") return `${entry.provider}/${entry.modelId}`;
	if (entry.type === "thinking_level_change") return entry.thinkingLevel ?? "";
	if (entry.type === "label") return `${entry.targetId}: ${entry.label ?? "(clear)"}`;
	if (entry.type === "session_info") return entry.name ?? "(unnamed)";
	return "";
}

function editorTextForEntry(entry: Entry): string {
	const message = asMessageLike(entry);
	if (entry.type === "message" && message?.role === "user") {
		return textFromContent(message.content);
	}
	if (entry.type === "custom_message") {
		return textFromContent(entry.content);
	}
	return "";
}

function branchSummaryIdForLeaf(
	ctx: ExtensionCommandContext,
	newLeafId: string | null | undefined,
	requestedSummary: boolean,
): string | undefined {
	if (!requestedSummary || !newLeafId) return undefined;
	const leafEntry = ctx.sessionManager.getEntry(newLeafId) as Entry | undefined;
	if (leafEntry?.type === "branch_summary") return newLeafId;
	if (leafEntry?.type === "label") {
		const labelledEntry = ctx.sessionManager.getEntry(leafEntry.targetId) as Entry | undefined;
		if (labelledEntry?.type === "branch_summary") return leafEntry.targetId;
	}
	return undefined;
}

function isBookkeepingEntry(entry: Entry): boolean {
	return (
		entry.type === "label" ||
		entry.type === "custom" ||
		entry.type === "model_change" ||
		entry.type === "thinking_level_change" ||
		entry.type === "session_info"
	);
}

function shouldShowInDefaultPicker(entry: Entry, currentLeafId: string | null | undefined): boolean {
	if (entry.type === "message" && entry.id !== currentLeafId) {
		const message = asMessageLike(entry);
		if (message?.role === "assistant") {
			const hasText = textFromContent(message.content).trim().length > 0;
			const stopReason = message.stopReason;
			const isErrorOrAborted = Boolean(stopReason && stopReason !== "stop" && stopReason !== "toolUse");
			if (!hasText && !isErrorOrAborted) return false;
		}
	}
	return !isBookkeepingEntry(entry);
}

function isConversationalEntry(entry: Entry): boolean {
	return (
		entry.type === "message" ||
		entry.type === "custom_message" ||
		entry.type === "branch_summary" ||
		entry.type === "compaction"
	);
}

function hasConversationalEntries(nodes: TreeNode[]): boolean {
	for (const node of nodes) {
		if (isConversationalEntry(node.entry)) return true;
		if (hasConversationalEntries(node.children ?? [])) return true;
	}
	return false;
}

function buildVisibleForest(
	nodes: TreeNode[],
	currentLeafId: string | null | undefined,
	options: PickerOptions,
): VisibleTreeNode[] {
	const visibleNodes: VisibleTreeNode[] = [];
	for (const node of nodes) {
		const visibleChildren = buildVisibleForest(node.children ?? [], currentLeafId, options);
		if (options.all || shouldShowInDefaultPicker(node.entry, currentLeafId)) {
			visibleNodes.push({ node, children: visibleChildren });
		} else {
			visibleNodes.push(...visibleChildren);
		}
	}
	return visibleNodes;
}

// TODO(rpc-tree): flattenChoices/buildVisibleForest/hasConversationalEntries/buildActivePathIds
// still recurse; convert them to iterative walkers if this becomes the default UI for very large/deep Pi traces.
function flattenChoices(
	nodes: TreeNode[],
	currentLeafId: string | null | undefined,
	options: PickerOptions = {},
): TreeChoice[] {
	const activePathIds = buildActivePathIds(nodes, currentLeafId);
	const visibleNodes = buildVisibleForest(nodes, currentLeafId, options);
	const choices: TreeChoice[] = [];

	function visit(visibleNode: VisibleTreeNode, prefix: string, isLast: boolean, depth: number) {
		const node = visibleNode.node;
		const entry = node.entry;
		if (!entry?.id) return;
		const connector = depth === 0 ? "" : isLast ? "└─ " : "├─ ";
		const active = entry.id === currentLeafId ? "● " : activePathIds.has(entry.id) ? "◆ " : "  ";
		const label = node.label ? ` [${node.label}]` : "";
		const role = entryRole(entry).padEnd(9).slice(0, 9);
		choices.push({
			id: entry.id,
			label: `${prefix}${connector}${active}${entry.id} ${role}${label} ${entryPreview(entry)}`,
		});
		const nextPrefix = depth === 0 ? "" : `${prefix}${isLast ? "   " : "│  "}`;
		const children = visibleNode.children;
		children.forEach((child, index) => visit(child, nextPrefix, index === children.length - 1, depth + 1));
	}

	visibleNodes.forEach((node, index) => visit(node, "", index === visibleNodes.length - 1, 0));
	return choices;
}

function buildActivePathIds(nodes: TreeNode[], currentLeafId: string | null | undefined): Set<string> {
	const active = new Set<string>();
	if (!currentLeafId) return active;
	function visit(node: TreeNode): boolean {
		if (node.entry?.id === currentLeafId) {
			active.add(node.entry.id);
			return true;
		}
		for (const child of node.children ?? []) {
			if (visit(child)) {
				active.add(node.entry.id);
				return true;
			}
		}
		return false;
	}
	for (const node of nodes) visit(node);
	return active;
}

function resolveEntryId(ctx: ExtensionCommandContext, rawId: string): string | undefined {
	const id = rawId.trim();
	if (!id) return undefined;
	if (ctx.sessionManager.getEntry(id)) return id;
	const matches = ctx.sessionManager
		.getEntries()
		.map((entry) => entry.id)
		.filter((entryId) => entryId.startsWith(id));
	return matches.length === 1 ? matches[0] : undefined;
}

function helpText(commandName: string): string {
	return [
		`/${commandName} - browse the session tree via RPC UI`,
		`/${commandName} [--all]`,
		`/${commandName} --id <entry-id> [--summary|--no-summary] [--label <label>]`,
		`/${commandName} <entry-id-prefix>`,
		"",
		"By default, the picker mirrors Pi /tree filtering and hides bookkeeping/tool-only noise.",
		"Use --all to include bookkeeping entries.",
		"Selecting a user/custom message moves to its parent and pre-fills the editor.",
		"Selecting assistant/tool/summary entries moves to that entry and clears the editor.",
	].join("\n");
}

function uiEditor(ctx: ExtensionCommandContext, title: string, prefill: string): Promise<string | undefined> {
	if (ctx.mode === "rpc") {
		// RPC editor requests currently have no timeout option. Use input(), which does,
		// so stale clients do not keep an orphaned editor request open after this command returns.
		return ctx.ui.input(title, prefill || "Use --custom=... for multi-line instructions", { timeout: UI_TIMEOUT_MS });
	}
	return ctx.ui.editor(title, prefill);
}

async function chooseSummary(ctx: ExtensionCommandContext, parsed: ParsedArgs): Promise<ParsedArgs | undefined> {
	if (parsed.summarize !== undefined || parsed.id) return parsed;
	const choice = await ctx.ui.select(
		"Summarize branch?",
		["No summary", "Summarize", "Summarize with custom instructions"],
		{ timeout: UI_TIMEOUT_MS },
	);
	if (!choice) return undefined;
	if (choice === "No summary") return { ...parsed, summarize: false };
	if (choice === "Summarize") return { ...parsed, summarize: true };
	const customInstructions = await uiEditor(ctx, "Custom summarization instructions", "");
	if (customInstructions === undefined) return undefined;
	return { ...parsed, summarize: true, customInstructions };
}

function setEditorTextAfterNavigation(ctx: ExtensionCommandContext, editorText: string) {
	if (ctx.mode === "rpc") {
		ctx.ui.setEditorText(editorText);
		return;
	}
	if (editorText && !ctx.ui.getEditorText().trim()) {
		ctx.ui.setEditorText(editorText);
	}
}

function emitRpcTreeEvent(ctx: ExtensionCommandContext, payload: Record<string, unknown>) {
	ctx.ui.notify(`${RPC_TREE_EVENT_PREFIX}${JSON.stringify({ version: 1, ...payload })}`, "info");
}

function messageFromError(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

function emitCommandTerminalEvent(
	ctx: ExtensionCommandContext,
	kind: "error" | "cancelled" | "noop",
	phase: string,
	message: string,
	extra: Record<string, unknown> = {},
) {
	const leafId = ctx.sessionManager.getLeafId();
	emitRpcTreeEvent(ctx, { kind, phase, oldLeafId: leafId, newLeafId: leafId, message, ...extra });
}

function emitCommandError(ctx: ExtensionCommandContext, phase: string, message: string, extra?: Record<string, unknown>) {
	emitCommandTerminalEvent(ctx, "error", phase, message, extra);
}

function emitCommandCancelled(ctx: ExtensionCommandContext, phase: string, message: string, extra?: Record<string, unknown>) {
	emitCommandTerminalEvent(ctx, "cancelled", phase, message, extra);
}

function emitCommandNoop(ctx: ExtensionCommandContext, phase: string, message: string, extra?: Record<string, unknown>) {
	emitCommandTerminalEvent(ctx, "noop", phase, message, extra);
}

function emitNavigationError(
	ctx: ExtensionCommandContext,
	base: NavigationEventBase,
	message: string,
	newLeafId = ctx.sessionManager.getLeafId(),
) {
	emitRpcTreeEvent(ctx, { kind: "error", phase: "navigation", ...base, newLeafId, message });
}

function emitNavigationCancelled(ctx: ExtensionCommandContext, base: NavigationEventBase, newLeafId: string | null) {
	emitRpcTreeEvent(ctx, { kind: "cancelled", phase: "navigation", ...base, newLeafId });
}

function emitNavigationSuccess(
	ctx: ExtensionCommandContext,
	base: NavigationEventBase,
	newLeafId: string | null,
	summaryEntryId: string | undefined,
	editorText: string,
	label: string | undefined,
) {
	emitRpcTreeEvent(ctx, {
		kind: "navigated",
		phase: "navigation",
		...base,
		newLeafId,
		summarized: summaryEntryId !== undefined,
		summaryEntryId,
		editorTextRestored: editorText.length > 0,
		label,
	});
}

function noPickerChoicesMessage(tree: TreeNode[], parsed: ParsedArgs, commandName: string): string {
	if (!parsed.all && !hasConversationalEntries(tree)) {
		return `No conversational entries yet. Try chatting first, or /${commandName} --all to inspect bookkeeping entries.`;
	}
	if (!parsed.all) return `No selectable entries after filtering. Try /${commandName} --all.`;
	return "No selectable tree entries.";
}

function notifyNoPickerChoices(ctx: ExtensionCommandContext, tree: TreeNode[], parsed: ParsedArgs, commandName: string) {
	const message = noPickerChoicesMessage(tree, parsed, commandName);
	emitCommandError(ctx, "picker", message, { all: parsed.all ?? false });
	ctx.ui.notify(message, "info");
}

async function chooseEntryFromFallbackPicker(
	ctx: ExtensionCommandContext,
	tree: TreeNode[],
	parsed: ParsedArgs,
	commandName: string,
): Promise<PickerSelection | undefined> {
	if (!ctx.hasUI) {
		const message = `/${commandName} needs extension UI, or pass --id <entry-id>`;
		emitCommandError(ctx, "ui", message);
		ctx.ui.notify(message, "error");
		return undefined;
	}

	const currentLeafId = ctx.sessionManager.getLeafId();
	const choices = flattenChoices(tree, currentLeafId, { all: parsed.all });
	if (choices.length === 0) {
		notifyNoPickerChoices(ctx, tree, parsed, commandName);
		return undefined;
	}

	const selectedLabel = await ctx.ui.select(
		"Pi session tree",
		choices.map((choice) => choice.label),
		{ timeout: UI_TIMEOUT_MS },
	);
	if (!selectedLabel) {
		const message = `No RPC UI response or tree selection cancelled. Use /${commandName} --id <entry-id>.`;
		emitCommandCancelled(ctx, "picker", message);
		ctx.ui.notify(message, "error");
		return undefined;
	}

	const selected = choices.find((choice) => choice.label === selectedLabel);
	if (!selected) {
		const message = "Tree selection not found";
		emitCommandError(ctx, "picker", message, { selectedLabel });
		ctx.ui.notify(message, "error");
		return undefined;
	}
	if (selected.id === currentLeafId) {
		const message = "Already at this point";
		emitCommandNoop(ctx, "picker", message, { targetId: selected.id });
		ctx.ui.notify(message, "info");
		return undefined;
	}

	const withSummaryChoice = await chooseSummary(ctx, parsed);
	if (!withSummaryChoice) {
		const message = "Tree navigation cancelled";
		emitCommandCancelled(ctx, "summary", message, { targetId: selected.id });
		ctx.ui.notify(message, "info");
		return undefined;
	}
	return { entryId: selected.id, parsed: withSummaryChoice };
}

async function navigate(ctx: ExtensionCommandContext, entryId: string, parsed: ParsedArgs) {
	const oldLeafId = ctx.sessionManager.getLeafId();
	const requestedSummary = parsed.summarize ?? false;
	const target = ctx.sessionManager.getEntry(entryId) as Entry | undefined;
	const base: NavigationEventBase = { targetId: entryId, oldLeafId, summarize: requestedSummary };

	if (!target) {
		const message = `Tree entry not found: ${entryId}`;
		emitNavigationError(ctx, base, message, oldLeafId);
		ctx.ui.notify(message, "error");
		return;
	}

	base.targetType = target.type;
	const editorText = editorTextForEntry(target);
	let result: { cancelled: boolean };
	try {
		result = await ctx.navigateTree(entryId, {
			summarize: requestedSummary,
			customInstructions: parsed.customInstructions,
			replaceInstructions: parsed.replaceInstructions,
			label: parsed.label,
		});
	} catch (error) {
		const message = messageFromError(error);
		emitNavigationError(ctx, base, message);
		ctx.ui.notify(`Tree navigation failed: ${message}`, "error");
		return;
	}

	const newLeafId = ctx.sessionManager.getLeafId();
	if (result.cancelled) {
		emitNavigationCancelled(ctx, base, newLeafId);
		ctx.ui.notify("Tree navigation cancelled", "info");
		return;
	}

	const summaryEntryId = branchSummaryIdForLeaf(ctx, newLeafId, requestedSummary);
	setEditorTextAfterNavigation(ctx, editorText);
	emitNavigationSuccess(ctx, base, newLeafId, summaryEntryId, editorText, parsed.label);
	ctx.ui.notify(`Tree navigated: target ${entryId}, leaf ${newLeafId ?? "root"}`, "info");
}

export default function (pi: ExtensionAPI) {
	const commandName = "rpc-tree";

	pi.registerCommand(commandName, {
		description: "Navigate the session tree in RPC mode",
		getArgumentCompletions: (prefix) => {
			const trimmed = prefix.trim();
			return ARG_COMPLETIONS.filter((option) => option.startsWith(trimmed)).map((value) => ({ value, label: value }));
		},
		handler: async (args, ctx) => {
			const parsedResult = parseArgs(args);
			if (!parsedResult.ok) {
				emitCommandError(ctx, "parse", parsedResult.error);
				ctx.ui.notify(`${parsedResult.error}\n\n${helpText(commandName)}`, "error");
				return;
			}

			const parsed = parsedResult.value;
			if (parsed.help) {
				ctx.ui.notify(helpText(commandName), "info");
				return;
			}

			await ctx.waitForIdle();

			const tree = ctx.sessionManager.getTree() as TreeNode[];
			if (tree.length === 0) {
				const message = "No entries in session tree";
				emitCommandError(ctx, "preflight", message);
				ctx.ui.notify(message, "info");
				return;
			}

			if (parsed.id) {
				const entryId = resolveEntryId(ctx, parsed.id);
				if (!entryId) {
					const message = `No unique tree entry matches: ${parsed.id}`;
					emitCommandError(ctx, "preflight", message, { targetId: parsed.id, summarize: parsed.summarize ?? false });
					ctx.ui.notify(message, "error");
					return;
				}
				await navigate(ctx, entryId, parsed);
				return;
			}

			const selection = await chooseEntryFromFallbackPicker(ctx, tree, parsed, commandName);
			if (!selection) return;
			await navigate(ctx, selection.entryId, selection.parsed);
		},
	});
}
