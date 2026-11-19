<script lang="ts">
	// HOMO: conversations with people, through Telegram (TDLib: src-tauri/src/tg.rs). Signed in once (the app's
	// api_id and api_hash from my.telegram.org, then the phone, its code, the password if there is one), it
	// stays so. The chats on the left, the one open on the right as TERM's and CHAT's: what I say on the
	// right, theirs on the left, the line to type at the bottom. ⌥↑ / ⌥↓ the chat above / below. NOVA: someone
	// to write to, found by @username, phone number or name.
	import { onMount, tick } from 'svelte';
	import { invoke, convertFileSrc } from '@tauri-apps/api/core';
	import { listen } from '@tauri-apps/api/event';
	import { getCurrentWindow } from '@tauri-apps/api/window';
	import History from './History.svelte';
	import { scrollFade } from './scrollFade';
	import { plain } from './emoji';

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
	interface Media {
		kind: 'photo' | 'video' | 'gif' | 'round';
		/** TDLib's file: the picture, or the video */
		file: number;
		/** a video's still, shown until it plays */
		thumb?: number;
		/** a tiny blurred picture of it, at once (a data: URL) */
		mini?: string;
		w: number;
		h: number;
	}

	interface Message {
		id: number;
		mine: boolean;
		text: string;
		sender: number;
		date: number;
		/** a picture or a video: shown (its words, the caption, under it) */
		media?: Media;
		/** a sticker: drawn as its outline (vector, in the ink), the words if it has none */
		sticker?: { file: number; w: number; h: number; outline?: any[] };
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

	const words = (content: any) => plain(said(content));

	function said(content: any): string {
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
			sticker: stickerOf(m.content),
			...withMedia(m.content),
		};
	}

	// ── pictures and videos: TDLib's files, downloaded into its folder and shown from there (the asset
	// protocol: tauri.conf.json). Photos and GIFs come at once; a video (or a round one) its still first,
	// itself when clicked ──

	/** where each file is on the disk, once downloaded */
	let paths: Record<number, string> = $state({});
	const fetching = new Set<number>();
	/** the videos clicked: they play */
	let playing: Record<number, boolean> = $state({});

	const known = (f: any) => {
		if (f?.local?.is_downloading_completed && f.local.path) paths[f.id] = f.local.path;
		return f?.id as number | undefined;
	};
	const mini = (m: any) => (m?.data ? `data:image/jpeg;base64,${m.data}` : undefined);

	/** a message with a picture or video: its media, and its words only the caption */
	function withMedia(content: any): { media?: Media; text?: string } {
		const caption = plain(content?.caption?.text ?? '');
		switch (content?.['@type']) {
			case 'messagePhoto': {
				const sizes = [...(content.photo?.sizes ?? [])].sort((a: any, b: any) => a.width - b.width);
				const size = sizes.filter((z: any) => z.width <= 1280).at(-1) ?? sizes.at(-1);
				const file = known(size?.photo);
				if (!file) return {};
				return { media: { kind: 'photo', file, mini: mini(content.photo.minithumbnail), w: size.width, h: size.height }, text: caption };
			}
			case 'messageVideo': {
				const v = content.video;
				const file = known(v?.video);
				if (!file) return {};
				return { media: { kind: 'video', file, thumb: known(v.thumbnail?.file), mini: mini(v.minithumbnail), w: v.width || 16, h: v.height || 9 }, text: caption };
			}
			case 'messageAnimation': {
				const a = content.animation;
				const file = known(a?.animation);
				if (!file) return {};
				return { media: { kind: 'gif', file, thumb: known(a.thumbnail?.file), mini: mini(a.minithumbnail), w: a.width || 1, h: a.height || 1 }, text: caption };
			}
			case 'messageVideoNote': {
				const n = content.video_note;
				const file = known(n?.video);
				if (!file) return {};
				return { media: { kind: 'round', file, thumb: known(n.thumbnail?.file), mini: mini(n.minithumbnail), w: 1, h: 1 }, text: '' };
			}
		}
		return {};
	}

	async function download(file: number | undefined) {
		if (!file || paths[file] || fetching.has(file)) return;
		fetching.add(file);
		const f = await request({ '@type': 'downloadFile', file_id: file, priority: 16, offset: 0, limit: 0, synchronous: true });
		if (f?.local?.is_downloading_completed) paths[file] = f.local.path;
		fetching.delete(file);
	}

	function play(media: Media) {
		playing[media.file] = true;
		download(media.file);
	}

	// what is on the page: its pictures, the videos' stills, the GIFs
	$effect(() => {
		for (const m of messages) {
			if (!m.media) continue;
			if (m.media.kind === 'photo' || m.media.kind === 'gif') download(m.media.file);
			download(m.media.thumb);
		}
	});

	// ── stickers as their outlines: Telegram's vector contour of each (the one it shows while the sticker
	// loads), filled in the ink: black and white, sharp at any size, nothing downloaded ──

	function stickerOf(content: any): Message['sticker'] {
		const st = content?.['@type'] === 'messageSticker' ? content.sticker : null;
		if (!st?.sticker?.id) return undefined;
		return { file: st.sticker.id, w: st.width || 512, h: st.height || 512, outline: st.outline };
	}

	/** each sticker's outline as an SVG path ('' when it has none), by its file */
	let outlines: Record<number, string> = $state({});
	const asking = new Set<number>();

	const point = (p: any) => `${+p.x.toFixed(1)} ${+p.y.toFixed(1)}`;

	/** TDLib's closed vector paths: each starts where its last command ends */
	function pathOf(paths: any[]): string {
		return (paths ?? [])
			.map((path: any) => {
				const commands = path.commands ?? [];
				if (!commands.length) return '';
				let d = 'M' + point(commands[commands.length - 1].end_point);
				for (const c of commands) {
					if (c['@type'] === 'vectorPathCommandCubicBezierCurve') d += `C${point(c.start_control_point)} ${point(c.end_control_point)} ${point(c.end_point)}`;
					else d += 'L' + point(c.end_point);
				}
				return d + 'Z';
			})
			.join('');
	}

	async function outlineOf(sticker: NonNullable<Message['sticker']>) {
		const file = sticker.file;
		if (file in outlines || asking.has(file)) return;
		// older TDLib: the outline comes with the sticker
		if (sticker.outline?.length) return (outlines[file] = pathOf(sticker.outline));
		asking.add(file);
		const ask = { sticker_file_id: file, for_animated_emoji: false, for_clicked_animated_emoji_message: false };
		// newer TDLib gives it as an SVG path at once; else its commands
		const svg = await request({ '@type': 'getStickerOutlineSvgPath', ...ask });
		if (svg['@type'] === 'text' && svg.text) outlines[file] = svg.text;
		else {
			const r = await request({ '@type': 'getStickerOutline', ...ask });
			outlines[file] = r['@type'] === 'outline' ? pathOf(r.paths) : '';
		}
		asking.delete(file);
	}

	$effect(() => {
		for (const m of messages) if (m.sticker) outlineOf(m.sticker);
	});

	function chatFrom(c: any): Chat {
		const main = (c.positions ?? []).find((p: any) => p.list?.['@type'] === 'chatListMain');
		return { id: c.id, title: plain(c.title || '—'), order: main?.order ?? '0', unread: c.unread_count ?? 0, last: words(c.last_message?.content) };
	}

	async function userName(id: number) {
		if (!id || users[id] !== undefined) return;
		users[id] = '';
		const u = await request({ '@type': 'getUser', user_id: id });
		if (u['@type'] === 'user') users[id] = plain([u.first_name, u.last_name].filter(Boolean).join(' '));
	}

	// ── what TDLib says ──

	function update(u: any) {
		const type = u['@type'];
		if (type === 'updateAuthorizationState') return authorization(u.authorization_state);
		if (type === 'updateNewChat') {
			chats[u.chat.id] = chatFrom(u.chat);
		} else if (type === 'updateChatTitle' && chats[u.chat_id]) {
			chats[u.chat_id].title = plain(u.title);
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
			if (m) {
				m.text = words(u.new_content);
				m.sticker = stickerOf(u.new_content);
				const media = withMedia(u.new_content);
				if (media.media) Object.assign(m, media);
			}
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
		find = '';
		found = [];
		problem = '';
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

	// ── NOVA: someone to write to ──

	let find = $state('');
	let findField: HTMLInputElement | undefined = $state();
	let found: { id: number; title: string }[] = $state([]);
	let finding = $state(false);

	function fresh() {
		if (open !== null) tell({ '@type': 'closeChat', chat_id: open });
		open = null;
		messages = [];
		problem = '';
		tick().then(() => findField?.focus());
	}

	const chatOf = async (userId: number) => {
		const c = await request({ '@type': 'createPrivateChat', user_id: userId, force: false });
		return c['@type'] === 'chat' ? c : null;
	};

	/** what was typed: a phone number, an @username, or a name among the chats and contacts */
	async function search() {
		const q = find.trim();
		if (!q) return (found = []);
		finding = true;
		problem = '';
		const results = new Map<number, string>();
		const add = (c: any) => c?.['@type'] === 'chat' && results.set(c.id, c.title || '—');
		if (/^\+?[\d\s()-]{5,}$/.test(q)) {
			const u = await request({ '@type': 'searchUserByPhoneNumber', phone_number: q.replace(/[^\d]/g, '') });
			if (u['@type'] === 'user') add(await chatOf(u.id));
		} else {
			const name = q.replace(/^@/, '');
			const [mine, contacts, pub] = await Promise.all([
				request({ '@type': 'searchChats', query: q, limit: 20 }),
				request({ '@type': 'searchContacts', query: q, limit: 20 }),
				/^[A-Za-z][\w]{3,}$/.test(name) ? request({ '@type': 'searchPublicChat', username: name }) : Promise.resolve(null),
			]);
			add(pub);
			for (const id of mine.chat_ids ?? []) add(chats[id] ? { '@type': 'chat', id, title: chats[id].title } : await request({ '@type': 'getChat', chat_id: id }));
			for (const id of contacts.user_ids ?? []) add(await chatOf(id));
		}
		found = [...results].map(([id, title]) => ({ id, title }));
		finding = false;
		if (!found.length) problem = 'No one found.';
	}

	async function findKey(e: KeyboardEvent) {
		if (e.key !== 'Enter' || e.isComposing) return;
		e.preventDefault();
		// a second Enter, the same words: the first found
		if (found.length && !finding) return openChat(found[0].id);
		await search();
		if (found.length === 1) openChat(found[0].id);
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
			} else if (!e.metaKey && !e.ctrlKey && !e.altKey && open === null && document.activeElement !== findField) {
				findField?.focus();
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
			} else if (stage === 'ready') findField?.focus();
			else askField?.focus();
		});
	});
</script>

<div class="page" class:hidden={!active}>
	{#if stage === 'ready'}
		{#if open !== null}<h1 class="shown-title">{chats[open]?.title ?? ''}</h1>{/if}
		<History
			items={ordered.map((c) => ({ id: c.id, title: c.title, badge: c.unread || undefined }))}
			shown={open}
			pick={(id) => openChat(Number(id))}
			{fresh}
			freshShown={open === null}
		/>
		<section class="talk">
			{#if open !== null}
				<div class="list" bind:this={list} use:scrollFade>
					{#each messages as m (m.id)}
						<div class="message" class:mine={m.mine} title={time(m.date)}>
							{#if isGroup && !m.mine && users[m.sender]}<span class="who">{users[m.sender]}</span>{/if}{#if m.media}{@const media = m.media}{@const src = paths[media.file] ? convertFileSrc(paths[media.file]) : ''}{@const still = media.thumb && paths[media.thumb] ? convertFileSrc(paths[media.thumb]) : media.mini}<div
									class="media {media.kind}"
									style="aspect-ratio: {media.w} / {media.h}; width: {media.kind === 'round' ? 240 : Math.min(420, Math.max(160, media.w))}px; {still ? `background-image: url('${still}');` : ''}"
								>
									{#if media.kind === 'photo'}
										{#if src}<img {src} alt={m.text} draggable="false" />{/if}
									{:else if media.kind === 'gif'}
										{#if src}<video {src} autoplay muted loop playsinline></video>{/if}
									{:else if playing[media.file] && src}
										<!-- svelte-ignore a11y_media_has_caption -->
										<video {src} autoplay controls playsinline></video>
									{:else}
										<button class="play" onclick={() => play(media)} aria-label="Play">{playing[media.file] ? '⋯' : '▶'}</button>
									{/if}
								</div>{#if m.text}<span class="caption">{m.text}</span>{/if}{:else if m.sticker && outlines[m.sticker.file]}<svg
									class="sticker" viewBox="0 0 {m.sticker.w} {m.sticker.h}" role="img" aria-label={m.text}><path d={outlines[m.sticker.file]} /></svg
								>{:else}{m.text}{/if}
						</div>
					{/each}
				</div>
				<div class="type">
					<textarea bind:this={field} bind:value={input} rows="1" spellcheck="false" oninput={grow} onkeydown={keydown}></textarea>
				</div>
			{:else}
				<div class="find">
					<p class="note">@username, the phone number, or a name</p>
					<input bind:this={findField} bind:value={find} oninput={() => (found = [])} onkeydown={findKey} spellcheck="false" />
					{#if finding}<p class="note">⋯</p>{/if}
					{#each found as f (f.id)}
						<button class="found" onclick={() => openChat(f.id)}>{f.title}</button>
					{/each}
					{#if problem}<p class="problem">{problem}</p>{/if}
				</div>
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
			{#if stage !== 'missing' && stage !== 'closed'}<button class="go" type="submit">&gt;</button>{/if}
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

	/* a picture or a video: square, as the glass is; the blurred still under it until it comes */
	.media {
		position: relative;
		max-width: 100%;
		max-height: 420px;
		background: center / cover no-repeat;
		overflow: hidden;
	}

	.message.mine .media {
		margin-left: auto;
	}

	.media.round {
		border-radius: 50%;
	}

	.media :is(img, video) {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.media.video video {
		object-fit: contain;
		background: #000;
	}

	.play {
		position: absolute;
		inset: 0;
		display: grid;
		place-items: center;
		background: rgba(0, 0, 0, 0.25);
		border: none;
		color: #fff;
		font-size: 28px;
		opacity: 0.85;
		cursor: pointer;
	}

	.play:hover {
		opacity: 1;
	}

	.caption {
		display: block;
		margin-top: 6px;
	}

	/* a sticker's outline, in the ink */
	.sticker {
		display: block;
		height: 110px;
		width: auto;
		max-width: 100%;
	}

	.sticker path {
		fill: var(--text);
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

	.find {
		margin: auto 0;
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.found {
		align-self: flex-start;
		background: transparent;
		border: none;
		color: var(--text);
		font: inherit;
		opacity: 0.75;
		cursor: pointer;
	}

	.found:hover {
		opacity: 1;
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
