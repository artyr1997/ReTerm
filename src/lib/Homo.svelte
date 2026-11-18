<script lang="ts">
	// HOMO: conversations with people, through Telegram (TDLib: src-tauri/src/tg.rs). Signed in once (the app's
	// api_id and api_hash from my.telegram.org, then the phone, its code, the password if there is one), it
	// stays so. The chats on the left, the one open on the right as TERM's and CHAT's: what I say on the
	// right, theirs on the left, the line to type at the bottom. ⌥↑ / ⌥↓ the chat above / below.
	import { onMount, tick } from 'svelte';
	import { invoke } from '@tauri-apps/api/core';
	import { listen } from '@tauri-apps/api/event';
	import { getCurrentWindow } from '@tauri-apps/api/window';
	import History from './History.svelte';
	import { scrollFade } from './scrollFade';

	let { active = false }: { active?: boolean } = $props();

	const KEYS = 'telegram-app';
	const me = getCurrentWindow().label;

	interface Chat {
		id: number;
		title: string;
		order: string;
		unread: number;
		last: string;
	}
	interface Message {
		id: number;
		mine: boolean;
		text: string;
		sender: number;
		date: number;
	}

	/** where signing in is: what is asked for next */
	let stage: 'loading' | 'missing' | 'app' | 'phone' | 'code' | 'password' | 'ready' | 'closed' = $state('loading');
	let problem = $state('');
	let hint = $state('');
	let ask = $state('');
	let askField: HTMLInputElement | undefined = $state();
	let apiId = $state('');
	let apiHash = $state('');
	let folder = '';

	let chats: Record<number, Chat> = $state({});
	const ordered = $derived(
		Object.values(chats)
			.filter((c) => c.order && c.order !== '0')
			.sort((a, b) => (BigInt(b.order) > BigInt(a.order) ? 1 : BigInt(b.order) < BigInt(a.order) ? -1 : 0)),
	);
	let open: number | null = $state(null);
	let messages: Message[] = $state([]);
	let users: Record<number, string> = $state({});
	let input = $state('');
	let field: HTMLTextAreaElement | undefined = $state();
	let list: HTMLDivElement | undefined = $state();

	let extra = 0;
	const waiting = new Map<string, (answer: any) => void>();

	/** a request to TDLib, and its answer */
	function request(body: Record<string, unknown>): Promise<any> {
		const id = `${me}:${++extra}`;
		return new Promise((done) => {
			waiting.set(id, done);
			invoke('tg_send', { json: JSON.stringify({ ...body, '@extra': id }) }).catch((err) => {
				waiting.delete(id);
				done({ '@type': 'error', message: String(err) });
			});
		});
	}
	const tell = (body: Record<string, unknown>) => invoke('tg_send', { json: JSON.stringify(body) }).catch(() => {});

	// ── what a message says, in words ──

	function words(content: any): string {
		if (!content) return '';
		const caption = content.caption?.text ? ' ' + content.caption.text : '';
		switch (content['@type']) {
			case 'messageText':
				return content.text?.text ?? '';
			case 'messagePhoto':
				return '[photo]' + caption;
			case 'messageVideo':
				return '[video]' + caption;
			case 'messageAnimation':
				return '[gif]' + caption;
			case 'messageDocument':
				return `[${content.document?.file_name || 'file'}]` + caption;
			case 'messageAudio':
				return `[${content.audio?.title || 'audio'}]` + caption;
			case 'messageVoiceNote':
				return '[voice]' + caption;
			case 'messageVideoNote':
				return '[video message]';
			case 'messageSticker':
				return `[${content.sticker?.emoji ?? ''} sticker]`;
			case 'messageLocation':
				return '[location]';
			case 'messageContact':
				return `[contact ${content.contact?.first_name ?? ''}]`;
			case 'messagePoll':
				return `[poll: ${content.poll?.question?.text ?? content.poll?.question ?? ''}]`;
			case 'messageCall':
				return '[call]';
			default:
				return '[' + String(content['@type']).replace(/^message/, '').replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase() + ']';
		}
	}

	function toMessage(m: any): Message {
		return {
			id: m.id,
			mine: !!m.is_outgoing,
			text: words(m.content),
			sender: m.sender_id?.user_id ?? m.sender_id?.chat_id ?? 0,
			date: m.date,
		};
	}

	function chatFrom(c: any): Chat {
		const main = (c.positions ?? []).find((p: any) => p.list?.['@type'] === 'chatListMain');
		return { id: c.id, title: c.title || '—', order: main?.order ?? '0', unread: c.unread_count ?? 0, last: words(c.last_message?.content) };
	}

	async function userName(id: number) {
		if (!id || users[id] !== undefined) return;
		users[id] = '';
		const u = await request({ '@type': 'getUser', user_id: id });
		if (u['@type'] === 'user') users[id] = [u.first_name, u.last_name].filter(Boolean).join(' ');
	}

	// ── what TDLib says ──

	function update(u: any) {
		const type = u['@type'];
		if (type === 'updateAuthorizationState') return authorization(u.authorization_state);
		if (type === 'updateNewChat') {
			chats[u.chat.id] = chatFrom(u.chat);
		} else if (type === 'updateChatTitle' && chats[u.chat_id]) {
			chats[u.chat_id].title = u.title;
		} else if (type === 'updateChatPosition' && chats[u.chat_id] && u.position?.list?.['@type'] === 'chatListMain') {
			chats[u.chat_id].order = u.position.order;
		} else if (type === 'updateChatLastMessage' && chats[u.chat_id]) {
			chats[u.chat_id].last = words(u.last_message?.content);
			const main = (u.positions ?? []).find((p: any) => p.list?.['@type'] === 'chatListMain');
			if (main) chats[u.chat_id].order = main.order;
		} else if (type === 'updateChatReadInbox' && chats[u.chat_id]) {
			chats[u.chat_id].unread = u.unread_count;
		} else if (type === 'updateNewMessage') {
			const m = u.message;
			if (m.chat_id === open && !messages.some((x) => x.id === m.id)) {
				messages.push(toMessage(m));
				if (!m.is_outgoing) userName(m.sender_id?.user_id);
				if (active) tell({ '@type': 'viewMessages', chat_id: open, message_ids: [m.id], force_read: true });
				stickToBottom();
			}
		} else if (type === 'updateMessageSendSucceeded') {
			const i = messages.findIndex((x) => x.id === u.old_message_id);
			if (i >= 0) messages[i] = toMessage(u.message);
		} else if (type === 'updateMessageContent' && u.chat_id === open) {
			const m = messages.find((x) => x.id === u.message_id);
			if (m) m.text = words(u.new_content);
		} else if (type === 'updateDeleteMessages' && u.chat_id === open && u.is_permanent) {
			messages = messages.filter((x) => !u.message_ids.includes(x.id));
		}
	}

	async function authorization(s: any) {
		problem = '';
		switch (s['@type']) {
			case 'authorizationStateWaitTdlibParameters': {
				if (!apiId || !apiHash) {
					stage = 'app';
					tick().then(() => askField?.focus());
					return;
				}
				const parameters = {
					use_test_dc: false,
					database_directory: folder,
					files_directory: folder,
					use_file_database: false,
					use_chat_info_database: true,
					use_message_database: true,
					use_secret_chats: false,
					api_id: Number(apiId),
					api_hash: apiHash,
					system_language_code: 'en',
					device_model: 'Mac',
					system_version: '',
					application_version: '0.1',
					enable_storage_optimizer: true,
				};
				// TDLib 1.8.0 takes them inside "parameters", newer ones as they are
				const r = await request({ '@type': 'setTdlibParameters', parameters: { '@type': 'tdlibParameters', ...parameters }, ...parameters, database_encryption_key: '' });
				if (r['@type'] === 'error') {
					problem = r.message;
					stage = 'app';
				}
				return;
			}
			case 'authorizationStateWaitEncryptionKey':
				return tell({ '@type': 'checkDatabaseEncryptionKey', encryption_key: '' });
			case 'authorizationStateWaitPhoneNumber':
				stage = 'phone';
				break;
			case 'authorizationStateWaitCode':
				stage = 'code';
				hint = String(s.code_info?.type?.['@type'] ?? '').includes('TelegramMessage') ? 'The code is in Telegram on another device.' : 'The code was sent to the phone.';
				break;
			case 'authorizationStateWaitPassword':
				stage = 'password';
				hint = s.password_hint ? `Hint: ${s.password_hint}` : '';
				break;
			case 'authorizationStateReady':
				stage = 'ready';
				loadChats();
				return;
			case 'authorizationStateClosed':
			case 'authorizationStateLoggingOut':
			case 'authorizationStateClosing':
				stage = 'closed';
				return;
			default:
				return;
		}
		ask = '';
		tick().then(() => askField?.focus());
	}

	async function submitAsk() {
		const value = ask.trim();
		let r: any = null;
		if (stage === 'app') {
			if (!/^\d+$/.test(apiId.trim()) || !apiHash.trim()) return (problem = 'Both, as my.telegram.org gives them.');
			apiId = apiId.trim();
			apiHash = apiHash.trim();
			try {
				localStorage.setItem(KEYS, JSON.stringify({ apiId, apiHash }));
			} catch {}
			r = await request({ '@type': 'getAuthorizationState' });
			return authorization(r);
		}
		if (!value) return;
		if (stage === 'phone') r = await request({ '@type': 'setAuthenticationPhoneNumber', phone_number: value });
		else if (stage === 'code') r = await request({ '@type': 'checkAuthenticationCode', code: value });
		else if (stage === 'password') r = await request({ '@type': 'checkAuthenticationPassword', password: value });
		if (r?.['@type'] === 'error') problem = r.message;
	}

	async function loadChats() {
		await request({ '@type': 'loadChats', chat_list: { '@type': 'chatListMain' }, limit: 100 });
		const r = await request({ '@type': 'getChats', chat_list: { '@type': 'chatListMain' }, limit: 100 });
		for (const id of r.chat_ids ?? []) {
			if (chats[id]) continue;
			request({ '@type': 'getChat', chat_id: id }).then((c) => {
				if (c['@type'] === 'chat') chats[c.id] = chatFrom(c);
			});
		}
	}

	// ── a chat open ──

	async function openChat(id: number) {
		if (open === id) return;
		if (open !== null) tell({ '@type': 'closeChat', chat_id: open });
		open = id;
		messages = [];
		tell({ '@type': 'openChat', chat_id: id });
		// TDLib gives what it has at hand first: asked again from the oldest, until there are enough
		let from = 0;
		let got: Message[] = [];
		for (let i = 0; i < 6 && got.length < 40; i++) {
			const r = await request({ '@type': 'getChatHistory', chat_id: id, from_message_id: from, offset: 0, limit: 50, only_local: false });
			if (open !== id) return;
			const batch: Message[] = (r.messages ?? []).map(toMessage);
			if (!batch.length) break;
			got = got.concat(batch);
			from = batch[batch.length - 1].id;
		}
		messages = got.reverse();
		for (const m of messages) if (!m.mine) userName(m.sender);
		if (messages.length && active) tell({ '@type': 'viewMessages', chat_id: id, message_ids: messages.slice(-50).map((m) => m.id), force_read: true });
		stickToBottom(true);
		field?.focus();
	}

	async function send() {
		const text = input.trim();
		if (!text || open === null) return;
		input = '';
		tick().then(grow);
		const r = await request({
			'@type': 'sendMessage',
			chat_id: open,
			input_message_content: { '@type': 'inputMessageText', text: { '@type': 'formattedText', text } },
		});
		if (r['@type'] === 'message' && r.chat_id === open && !messages.some((x) => x.id === r.id)) {
			messages.push(toMessage(r));
			stickToBottom(true);
		} else if (r['@type'] === 'error') problem = r.message;
	}

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

	function step(by: number) {
		if (!ordered.length) return;
		const at = ordered.findIndex((c) => c.id === open);
		const next = ordered[Math.min(ordered.length - 1, Math.max(0, at < 0 ? 0 : at + by))];
		openChat(next.id);
	}

	function keydown(e: KeyboardEvent) {
		if (e.isComposing) return;
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			send();
		}
	}

	const time = (date: number) => new Date(date * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
	/** more than one other person writes in it: their names over their words */
	const isGroup = $derived(new Set(messages.filter((m) => !m.mine).map((m) => m.sender)).size > 1);

	onMount(() => {
		try {
			const kept = JSON.parse(localStorage.getItem(KEYS) ?? 'null');
			apiId = kept?.apiId ?? '';
			apiHash = kept?.apiHash ?? '';
		} catch {}
		let off: (() => void) | null = null;
		const keys = (e: KeyboardEvent) => {
			if (!active || stage !== 'ready') return;
			if (e.altKey && !e.metaKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
				e.preventDefault();
				step(e.key === 'ArrowUp' ? -1 : 1);
			} else if (!e.metaKey && !e.ctrlKey && !e.altKey && open !== null && document.activeElement !== field) {
				field?.focus();
			}
		};
		addEventListener('keydown', keys);
		(async () => {
			off = await listen<string>('tg', (e) => {
				let u: any;
				try {
					u = JSON.parse(e.payload);
				} catch {
					return;
				}
				const id = u['@extra'];
				if (id && waiting.has(id)) {
					waiting.get(id)!(u);
					waiting.delete(id);
				} else if (!id) update(u);
			});
			try {
				folder = await invoke<string>('tg_start');
			} catch (err) {
				stage = 'missing';
				problem = String(err);
				return;
			}
			authorization(await request({ '@type': 'getAuthorizationState' }));
		})();
		return () => {
			removeEventListener('keydown', keys);
			off?.();
		};
	});

	// shown: the keys are its, the chat open read
	$effect(() => {
		if (!active) return;
		tick().then(() => {
			if (stage === 'ready' && open !== null) {
				field?.focus();
				if (messages.length) tell({ '@type': 'viewMessages', chat_id: open, message_ids: messages.slice(-50).map((m) => m.id), force_read: true });
			} else askField?.focus();
		});
	});
</script>

<div class="page" class:hidden={!active}>
	{#if stage === 'ready'}
		<History
			items={ordered.map((c) => ({ id: c.id, title: c.title, badge: c.unread || undefined }))}
			shown={open}
			pick={(id) => openChat(Number(id))}
		/>
		<section class="talk">
			{#if open !== null}
				<div class="list" bind:this={list} use:scrollFade>
					{#each messages as m (m.id)}
						<div class="message" class:mine={m.mine} title={time(m.date)}>
							{#if isGroup && !m.mine && users[m.sender]}<span class="who">{users[m.sender]}</span>{/if}{m.text}
						</div>
					{/each}
				</div>
				<div class="type">
					<p class="where">{chats[open]?.title ?? ''}</p>
					<textarea bind:this={field} bind:value={input} rows="1" spellcheck="false" oninput={grow} onkeydown={keydown}></textarea>
				</div>
			{:else}
				<p class="quiet">⌥↑ ⌥↓</p>
			{/if}
		</section>
	{:else if stage === 'loading'}
		<p class="quiet">TELEGRAM</p>
	{:else}
		<form
			class="sign"
			onsubmit={(e) => {
				e.preventDefault();
				submitAsk();
			}}
		>
			<p class="heading">TELEGRAM</p>
			{#if stage === 'missing'}
				<p class="note">TDLib isn't installed. In TERM: brew install tdlib</p>
			{:else if stage === 'closed'}
				<p class="note">Signed out.</p>
			{:else if stage === 'app'}
				<p class="note">The app's api_id and api_hash, from my.telegram.org → API development tools</p>
				<input bind:this={askField} bind:value={apiId} placeholder="api_id" inputmode="numeric" />
				<input bind:value={apiHash} placeholder="api_hash" />
			{:else}
				<p class="note">
					{stage === 'phone' ? 'The phone number, with its country code' : stage === 'code' ? hint : hint || 'The password (two-step verification)'}
				</p>
				<input
					bind:this={askField}
					bind:value={ask}
					type={stage === 'password' ? 'password' : 'text'}
					placeholder={stage === 'phone' ? '+380…' : stage === 'code' ? 'code' : 'password'}
				/>
			{/if}
			{#if problem}<p class="problem">{problem}</p>{/if}
			{#if stage !== 'missing' && stage !== 'closed'}<button class="go" type="submit">→</button>{/if}
		</form>
	{/if}
</div>

<style>
	.page {
		position: fixed;
		inset: var(--area);
		display: flex;
		font-family: var(--font);
		font-size: 14px;
		line-height: 1.5;
	}

	.page.hidden {
		visibility: hidden;
	}

	.talk {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
	}

	.list {
		flex: 1;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding-bottom: 12px;
	}

	.list > :first-child {
		margin-top: auto;
	}

	.message {
		max-width: 80%;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		user-select: text;
		cursor: text;
	}

	.message.mine {
		align-self: flex-end;
	}

	.who {
		display: block;
		font-size: 0.8em;
		opacity: 0.5;
	}

	.type {
		flex-shrink: 0;
		padding-top: 6px;
	}

	.where {
		font-size: 0.8em;
		opacity: 0.5;
		margin-bottom: 4px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	textarea,
	input {
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
	}

	.quiet {
		margin: auto;
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 12px;
		letter-spacing: 0.3em;
		opacity: 0.4;
	}

	.sign {
		margin: auto;
		width: min(420px, 100%);
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.heading {
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 14px;
		letter-spacing: 0.4em;
		text-align: center;
	}

	.note {
		font-size: 0.85em;
		opacity: 0.6;
	}

	.problem {
		font-size: 0.85em;
		color: var(--c1, #a5534d);
	}

	.go {
		align-self: flex-end;
		background: transparent;
		border: none;
		color: var(--text);
		font-size: 20px;
		cursor: pointer;
		opacity: 0.75;
	}

	.go:hover {
		opacity: 1;
	}

	:global(html.glass) :is(textarea, input) {
		border-bottom-width: 1px;
	}
</style>
