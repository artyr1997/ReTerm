<script lang="ts">
	// CHAT: a conversation with an LLM, as TERM's with the shell: what is said on the right, the answer under
	// it as it comes. Through the programs installed and signed in (claude, codex: src-tauri/src/llm.rs); the
	// conversation goes on by its session until ⌘K starts a new one. Kept between launches.
	import { onMount, tick } from 'svelte';
	import { invoke } from '@tauri-apps/api/core';
	import { getCurrentWebview } from '@tauri-apps/api/webview';

	let { active = false }: { active?: boolean } = $props();

	const KEY = 'chat';
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

	let messages: Message[] = $state([]);
	let sessions: Record<string, string> = $state({});
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

	function load() {
		try {
			const saved = JSON.parse(localStorage.getItem(KEY) ?? 'null');
			if (!saved) return;
			messages = (saved.messages ?? []).map((m: Message) => ({ ...m, coming: false }));
			sessions = saved.sessions ?? {};
			provider = saved.provider ?? 'claude';
			nextId = Math.max(0, ...messages.map((m) => m.id)) + 1;
			history = messages.filter((m) => m.me).map((m) => m.text);
		} catch {}
	}

	function keep() {
		try {
			localStorage.setItem(KEY, JSON.stringify({ messages, sessions, provider }));
		} catch {}
	}

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
		if (!text || answering !== null || !available.includes(provider)) return;
		messages.push({ id: nextId++, me: true, text });
		const answer: Message = { id: nextId++, me: false, text: '', provider, coming: true };
		messages.push(answer);
		if (history.at(-1) !== text) history.push(text);
		historyAt = -1;
		setInput('');
		answering = answer.id;
		streamed = false;
		stickToBottom(true);
		keep();
		await invoke('llm_send', { id: answer.id, provider, prompt: text, session: sessions[provider] ?? null, model: null }).catch((err) => {
			finish(answer.id, String(err));
		});
	}

	const byId = (id: number) => messages.find((m) => m.id === id);

	/** a line the program wrote */
	function line(id: number, text: string) {
		const message = byId(id);
		if (!message) return;
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
		const message = byId(id);
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

	/** a new conversation: the old one forgotten */
	function fresh() {
		stop();
		messages = [];
		sessions = {};
		keep();
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
	<div class="list" bind:this={list}>
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

<style>
	.page {
		position: fixed;
		inset: var(--area);
		display: flex;
		flex-direction: column;
		font-family: 'M PLUS 1 Code', Menlo, monospace;
		font-size: var(--size, 14px);
		line-height: 1.5;
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
