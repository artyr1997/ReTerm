<script lang="ts">
	// CHAT: a conversation with an LLM, as TERM's with the shell: what is said on the right, the answer under
	// it as it comes. Through the programs installed and signed in (claude, codex: src-tauri/src/llm.rs); the
	// conversation goes on by its session until ⌘K starts a new one. The ones before on the left, each to go
	// on with (its sessions kept); ⌥↑ / ⌥↓ the one above / below. Kept between launches.
	import { onMount, tick } from 'svelte';
	import { invoke } from '@tauri-apps/api/core';
	import { getCurrentWebview } from '@tauri-apps/api/webview';
	import History from './History.svelte';
	import { scrollFade } from './scrollFade';

	let { active = false }: { active?: boolean } = $props();

	const KEY = 'chats';
	/** before there were several: the one conversation */
	const OLD_KEY = 'chat';
	const MOST = 200;
	const NAMES: Record<string, string> = { claude: 'CLAUDE', codex: 'CODEX' };

	interface Message {
		id: number;
		me: boolean;
		text: string;
		provider?: string;
		/** the answer still coming */
		coming?: boolean;
		error?: string;
	}

	interface Conversation {
		id: number;
		/** when it began, and when last said in (ms) */
		started: number;
		last: number;
		messages: Message[];
		/** each program's session, to go on with */
		sessions: Record<string, string>;
	}

	let conversations: Conversation[] = $state([]);
	let shownId = $state(0);
	const shown = $derived(conversations.find((c) => c.id === shownId));
	const messages = $derived(shown?.messages ?? []);
	/** changed in this window since kept: what is written back (another window keeps its own) */
	const changed = new Set<number>();
	let provider = $state('claude');
	let available: string[] = $state([]);
	let nextId = 1;
	let input = $state('');
	let field: HTMLTextAreaElement | undefined = $state();
	let list: HTMLDivElement | undefined = $state();
	let history: string[] = [];
	let historyAt = -1;
	let draft = '';
	/** the message being answered, and whether its words came piece by piece */
	let answering: number | null = $state(null);
	let streamed = false;

	function stored(): { conversations: Conversation[]; provider?: string } {
		try {
			const saved = JSON.parse(localStorage.getItem(KEY) ?? 'null');
			if (saved?.conversations) return saved;
			// the one conversation of before: the first of the history
			const old = JSON.parse(localStorage.getItem(OLD_KEY) ?? 'null');
			if (old?.messages?.length) {
				const now = Date.now() - 1;
				return { conversations: [{ id: now, started: now, last: now, messages: old.messages, sessions: old.sessions ?? {} }], provider: old.provider };
			}
		} catch {}
		return { conversations: [] };
	}

	function load() {
		const saved = stored();
		conversations = saved.conversations.map((c) => ({ ...c, messages: c.messages.map((m) => ({ ...m, coming: false })) }));
		// the one of before: now kept as one of several
		if (localStorage.getItem(KEY) === null) for (const c of conversations) changed.add(c.id);
		provider = saved.provider ?? 'claude';
		nextId = Math.max(0, ...conversations.flatMap((c) => c.messages.map((m) => m.id))) + 1;
		history = conversations
			.slice()
			.sort((a, b) => a.last - b.last)
			.flatMap((c) => c.messages.filter((m) => m.me).map((m) => m.text));
		// a new one shown, the others on the left
		fresh();
	}

	/** this window's changes written over what is kept (another window's kept too) */
	function keep() {
		try {
			const saved = stored().conversations.filter((c) => !changed.has(c.id));
			const mine = conversations.filter((c) => changed.has(c.id) && c.messages.length);
			const all = [...saved, ...mine].sort((a, b) => b.last - a.last).slice(0, MOST);
			localStorage.setItem(KEY, JSON.stringify({ conversations: all, provider }));
			localStorage.removeItem(OLD_KEY);
			changed.clear();
			// what another window said meanwhile: on the left here too
			for (const c of all) if (!conversations.some((x) => x.id === c.id)) conversations.push(c);
		} catch {}
	}

	/** the conversations on the left: the newest first; the one shown, said nothing yet, at the top */
	const listed = $derived(
		conversations
			.filter((c) => c.messages.length || c.id === shownId)
			.sort((a, b) => (a.messages.length ? 1 : 0) - (b.messages.length ? 1 : 0) || b.last - a.last),
	);
	const title = (c: Conversation) => (c.messages.find((m) => m.me)?.text ?? 'NEW').split('\n')[0].slice(0, 80);
	const when = (ms: number) => new Date(ms).toLocaleString([], { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });

	// ── a little markdown: code blocks, `code`, **bold**, headings ──

	const escapeHTML = (s: string) => s.replace(/[&<>]/g, (c) => (c === '&' ? '&amp;' : c === '<' ? '&lt;' : '&gt;'));

	function inline(s: string) {
		return escapeHTML(s)
			.replace(/`([^`\n]+)`/g, '<code>$1</code>')
			.replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>')
			.replace(/^#{1,6} (.*)$/gm, '<b>$1</b>');
	}

	function markdown(text: string) {
		return text
			.split('```')
			.map((part, i) => (i % 2 ? `<span class="code">${escapeHTML(part.replace(/^[^\n]*\n/, '').replace(/\n$/, ''))}</span>` : inline(part)))
			.join('');
	}

	// ── talking ──

	function stickToBottom(always = false) {
		if (!list) return;
		const near = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
		if (always || near) tick().then(() => list && (list.scrollTop = list.scrollHeight));
	}

	function grow() {
		if (!field) return;
		field.style.height = 'auto';
		field.style.height = field.scrollHeight + 'px';
	}

	function setInput(text: string) {
		input = text;
		tick().then(() => {
			grow();
			field?.setSelectionRange(text.length, text.length);
		});
	}

	async function send() {
		const text = input.trim();
		if (!text || answering !== null || !available.includes(provider) || !shown) return;
		const conversation = shown;
		conversation.messages.push({ id: nextId++, me: true, text });
		conversation.messages.push({ id: nextId++, me: false, text: '', provider, coming: true });
		const answer = conversation.messages.at(-1)!;
		conversation.last = Date.now();
		changed.add(conversation.id);
		if (history.at(-1) !== text) history.push(text);
		historyAt = -1;
		setInput('');
		answering = answer.id;
		streamed = false;
		stickToBottom(true);
		keep();
		await invoke('llm_send', { id: answer.id, provider, prompt: text, session: conversation.sessions[provider] ?? null, model: null }).catch((err) => {
			finish(answer.id, String(err));
		});
	}

	/** a message, and its conversation (shown or not: an answer comes on while another is looked at) */
	function byId(id: number): [Message, Conversation] | [] {
		for (const c of conversations) {
			const m = c.messages.find((m) => m.id === id);
			if (m) return [m, c];
		}
		return [];
	}

	/** a line the program wrote */
	function line(id: number, text: string) {
		const [message, conversation] = byId(id);
		if (!message || !conversation) return;
		changed.add(conversation.id);
		const sessions = conversation.sessions;
		let event: any;
		try {
			event = JSON.parse(text);
		} catch {
			// not its JSON (a program that writes plain text)
			if (message.provider !== 'claude') message.text += text + '\n';
			return stickToBottom();
		}
		if (message.provider === 'claude') {
			if (event.session_id) sessions.claude = event.session_id;
			if (event.type === 'stream_event' && event.event?.type === 'content_block_delta' && event.event.delta?.type === 'text_delta') {
				message.text += event.event.delta.text;
				streamed = true;
			} else if (event.type === 'stream_event' && event.event?.type === 'content_block_start' && message.text && !message.text.endsWith('\n')) {
				message.text += '\n\n';
			} else if (event.type === 'assistant' && !streamed) {
				const words = (event.message?.content ?? []).filter((c: any) => c.type === 'text').map((c: any) => c.text).join('');
				if (words) message.text += words;
			} else if (event.type === 'result' && event.is_error) {
				message.error = String(event.result ?? 'Error');
			}
		} else {
			// codex exec --json: the thread, and each message as it is done
			if (event.thread_id) sessions.codex = event.thread_id;
			const item = event.item ?? event.msg;
			if (event.type === 'item.completed' && item?.type === 'agent_message' && item.text) message.text += (message.text ? '\n\n' : '') + item.text;
			else if (event.type === 'error' || event.type === 'turn.failed') message.error = String(event.message ?? event.error?.message ?? 'Error');
		}
		stickToBottom();
	}

	function finish(id: number, error: string) {
		const [message, conversation] = byId(id);
		if (conversation) changed.add(conversation.id);
		if (message) {
			message.coming = false;
			if (error && !message.text) message.error = message.error || error;
		}
		if (answering === id) answering = null;
		keep();
		stickToBottom();
	}

	function stop() {
		if (answering !== null) invoke('llm_stop', { id: answering });
	}

	/** a new conversation: the one before kept on the left (one said nothing in: it is the new one) */
	function fresh() {
		if (shown && !shown.messages.length) return;
		const now = Date.now();
		conversations.push({ id: now, started: now, last: now, messages: [], sessions: {} });
		shownId = now;
		tick().then(() => field?.focus());
	}

	function show(id: number) {
		if (id === shownId) return;
		// the new one said nothing in: no need of it
		if (shown && !shown.messages.length) conversations = conversations.filter((c) => c.id !== shownId);
		shownId = id;
		stickToBottom(true);
		tick().then(() => field?.focus());
	}

	/** ⌥↑ / ⌥↓: the conversation above / below on the left */
	function step(by: number) {
		const at = listed.findIndex((c) => c.id === shownId);
		const next = listed[Math.min(listed.length - 1, Math.max(0, at + by))];
		if (next) show(next.id);
	}

	function choose(name: string) {
		provider = name;
		keep();
		field?.focus();
	}

	function keydown(e: KeyboardEvent) {
		if (e.isComposing) return;
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			send();
		} else if ((e.ctrlKey && e.key === 'c' && !String(getSelection() ?? '')) || e.key === 'Escape') {
			if (answering !== null) {
				e.preventDefault();
				stop();
			} else if (e.ctrlKey) {
				e.preventDefault();
				setInput('');
			}
		} else if ((e.metaKey && e.key === 'k') || (e.ctrlKey && e.key === 'l')) {
			e.preventDefault();
			fresh();
		} else if (e.altKey && !e.metaKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
			e.preventDefault();
			step(e.key === 'ArrowUp' ? -1 : 1);
		} else if (e.key === 'ArrowUp' && field && !input.slice(0, field.selectionStart).includes('\n')) {
			if (!history.length) return;
			e.preventDefault();
			if (historyAt < 0) {
				draft = input;
				historyAt = history.length;
			}
			historyAt = Math.max(0, historyAt - 1);
			setInput(history[historyAt]);
		} else if (e.key === 'ArrowDown' && field && historyAt >= 0 && !input.slice(field.selectionEnd).includes('\n')) {
			e.preventDefault();
			historyAt++;
			if (historyAt >= history.length) {
				historyAt = -1;
				setInput(draft);
			} else setInput(history[historyAt]);
		} else if (e.key === 'Tab' && available.length > 1) {
			// Tab: the other one
			e.preventDefault();
			choose(available[(available.indexOf(provider) + 1) % available.length]);
		}
	}

	function pageClick() {
		if (!active || String(getSelection() ?? '')) return;
		field?.focus();
	}

	onMount(() => {
		load();
		invoke<string[]>('llm_available').then((found) => {
			available = found;
			if (found.length && !found.includes(provider)) provider = found[0];
		});
		const webview = getCurrentWebview();
		const offs = [
			webview.listen<{ id: number; line: string }>('llm-line', (e) => line(e.payload.id, e.payload.line)),
			webview.listen<{ id: number; code: number; error: string }>('llm-done', (e) =>
				finish(e.payload.id, e.payload.code === 0 ? '' : e.payload.error || `exit ${e.payload.code}`),
			),
		];
		const anyKey = (e: KeyboardEvent) => {
			if (!active || e.metaKey || e.ctrlKey || e.altKey) return;
			if (document.activeElement !== field) field?.focus();
		};
		addEventListener('keydown', anyKey);
		return () => {
			removeEventListener('keydown', anyKey);
			offs.forEach((off) => off.then((f) => f()));
		};
	});

	// shown: the keys are its
	$effect(() => {
		if (active) tick().then(() => {
			field?.focus();
			stickToBottom(true);
		});
	});
</script>

<!-- svelte-ignore a11y_click_events_have_key_events -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="page" class:hidden={!active} onclick={pageClick}>
	<History
		items={listed.map((c) => ({ id: c.id, title: title(c), hint: when(c.started) }))}
		shown={shownId}
		pick={(id) => show(Number(id))}
	/>
	<div class="talk">
	<div class="list" bind:this={list} use:scrollFade>
		{#each messages as message (message.id)}
			{#if message.me}
				<div class="said">{message.text}</div>
			{:else}
				<div class="answer" class:coming={message.coming}>
					{@html markdown(message.text)}{#if message.coming && !message.text}<span class="busy">⋯</span>{/if}
				</div>
				{#if message.error}<p class="status">✕ {message.error}</p>{/if}
			{/if}
		{/each}
	</div>

	<div class="type">
		<p class="where">
			{#each available as name}
				<button class="who" onclick={() => choose(name)}><span class:ink-mark={name === provider}>{NAMES[name] ?? name}</span></button>
			{:else}
				<span class="none">claude / codex: not installed</span>
			{/each}
			{#if answering !== null}<span class="busy"> ⋯</span>{/if}
		</p>
		<textarea
			bind:this={field}
			bind:value={input}
			rows="1"
			spellcheck="false"
			autocomplete="off"
			oninput={grow}
			onkeydown={keydown}
		></textarea>
	</div>
	</div>
</div>

<style>
	.page {
		position: fixed;
		inset: var(--area);
		display: flex;
		font-family: var(--font);
		font-size: var(--size, 14px);
		line-height: 1.5;
	}

	.talk {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
	}

	.page.hidden {
		visibility: hidden;
	}

	.list {
		flex: 1;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding-bottom: 12px;
	}

	.list > :first-child {
		margin-top: auto;
	}

	.said {
		align-self: flex-end;
		max-width: 80%;
		margin-top: 8px;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		user-select: text;
		cursor: text;
	}

	.answer {
		max-width: 92%;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		user-select: text;
		cursor: text;
	}

	.answer :global(code) {
		font: inherit;
		opacity: 0.8;
	}

	.answer :global(.code) {
		display: block;
		margin: 6px 0;
		padding-left: 14px;
		border-left: 2px solid var(--line);
		opacity: 0.9;
	}

	.status {
		margin-top: -8px;
		font-size: 0.85em;
		opacity: 0.5;
		white-space: pre-wrap;
	}

	.type {
		flex-shrink: 0;
		padding-top: 6px;
	}

	.where {
		display: flex;
		align-items: center;
		gap: 18px;
		margin-bottom: 6px;
		font-size: 0.8em;
	}

	.who {
		background: transparent;
		border: none;
		padding: 0.25em 0.35em;
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 11px;
		letter-spacing: 0.3em;
		opacity: 0.75;
		cursor: pointer;
	}

	.who:hover {
		opacity: 1;
	}

	.none {
		opacity: 0.5;
	}

	.busy {
		animation: breathe 1.6s ease-in-out infinite;
	}

	@keyframes breathe {
		50% {
			opacity: 0.2;
		}
	}

	textarea {
		display: block;
		width: 100%;
		max-height: 40vh;
		resize: none;
		border: none;
		border-bottom: 2px solid var(--line);
		padding: 4px 0 8px;
		background: transparent;
		color: var(--text);
		caret-color: var(--text);
		font: inherit;
		line-height: 1.25;
		outline: none;
		overflow-y: auto;
	}

	:global(html.glass) textarea,
	:global(html.glass) .answer :global(.code) {
		border-width: 1px;
	}
</style>
