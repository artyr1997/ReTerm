<script lang="ts">
	// The history of conversations, on the left of the one shown (TERM's sessions, HOMO's chats, CHAT's
	// conversations): their names, the one shown inked; a click shows it. Its lines fade at the edges, as
	// the other apps' lists. Gone in a small window (app.css .history).
	import { scrollFade } from './scrollFade';
	import { t } from './lang.svelte';

	export interface Item {
		id: number | string;
		title: string;
		/** a little after its name: unread messages, … */
		badge?: string | number;
		/** on hovering it: when, … */
		hint?: string;
	}

	let {
		items,
		shown = null,
		pick,
		fresh,
		freshShown = false,
	}: {
		items: Item[];
		shown?: number | string | null;
		pick: (id: number | string) => void;
		/** NOVA, always at the top: a new conversation (inked while it is the one shown) */
		fresh?: () => void;
		freshShown?: boolean;
	} = $props();
</script>

<nav class="history" use:scrollFade>
	{#if fresh}
		<button class="item" class:shown={freshShown} onclick={fresh}>
			<span class="title"><span class:ink-mark={freshShown}>{t('NOVA')}</span></span>
		</button>
	{/if}
	{#each items as item (item.id)}
		<button class="item" class:shown={item.id === shown} title={item.hint ?? item.title} onclick={() => pick(item.id)}>
			<span class="title"><span class:ink-mark={item.id === shown}>{item.title}</span></span>
			{#if item.badge}<span class="badge">{item.badge}</span>{/if}
		</button>
	{/each}
</nav>

<style>
	.history {
		flex-shrink: 0;
		width: calc(var(--list) - 40px);
		margin-right: 40px;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.item {
		flex-shrink: 0;
		display: flex;
		align-items: baseline;
		gap: 10px;
		padding: 5px 0;
		background: transparent;
		border: none;
		color: var(--text);
		font-family: var(--font);
		font-size: 14px;
		line-height: 1.5;
		text-align: left;
		opacity: 0.75;
		cursor: pointer;
		transition: opacity 200ms ease;
	}

	.item:hover,
	.item.shown {
		opacity: 1;
	}

	.title {
		flex: 1;
		min-width: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		padding: 0.25em 0.45em;
	}

	.badge {
		font-size: 0.8em;
		opacity: 0.6;
	}
</style>
