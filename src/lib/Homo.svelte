<script lang="ts">
	// HOMO: conversations with people (Telegram). To come.
	let { active = false }: { active?: boolean } = $props();
</script>

<div class="page" class:hidden={!active}>
	<p class="soon">TELEGRAM</p>
</div>

<style>
	.page {
		position: fixed;
		inset: var(--area);
		display: grid;
		place-items: center;
	}

	.page.hidden {
		visibility: hidden;
	}

	.soon {
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 12px;
		letter-spacing: 0.3em;
		opacity: 0.4;
	}
</style>
