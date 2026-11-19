// The emoji in one colour, the ink's (Noto Emoji, app.css --font). One asked to be drawn in colour (U+FE0F
// after it: ❤️ ✳️) would take the Mac's colour emoji whatever the font; it is asked for as text instead (U+FE0E).
export const plain = (text: string) => text.replace(/️/g, '︎');
