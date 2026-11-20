// Menu bar glyphs (template images), 36×36 = 18 pt @2x. Same code as the
// Design canvas boards F/G (MenuBarGlyphs / MenuBarStatus); render with
//     Scripts/make-menu-bar-icons.sh
// Shared menu bar glyphs, 36×36 (18 pt @2x). c = template colour.
const T = 'M7.5,6.5 L14,5.2 L21,5.8 L24.5,5.2 L26.8,7.6 L28.6,8 L29.2,14 L28.4,21 L29.2,31 L7,31 L6.8,23 L7.6,17 L6.6,11 Z';
const r1 = (n) => Math.round(n * 10) / 10;
const aten = (cx, cy, r, ends, w, hand) => {
  let s = '<circle cx="' + cx + '" cy="' + cy + '" r="' + r + '"/>';
  for (const [ex, ey] of ends) {
    const b = Math.atan2(ey - cy, ex - cx), r0 = r + 1.8;
    s += '<path d="M' + r1(cx + Math.cos(b) * r0) + ',' + r1(cy + Math.sin(b) * r0) + ' L' + ex + ',' + ey + '" stroke-width="' + w + '" stroke-linecap="round" fill="none"/>' + (hand ? '<ellipse cx="' + ex + '" cy="' + ey + '" rx="' + r1(hand * 0.75) + '" ry="' + hand + '" transform="rotate(' + r1(b * 180 / Math.PI - 90) + ' ' + ex + ' ' + ey + ')"/>' : '');
  }
  return s;
};
const akhet = '<defs><mask id="ak"><rect width="36" height="36" fill="#fff"/><path d="M5.5,28 L5.5,25 C8,20.5 11,18.5 13.5,18.5 C15.5,18.5 17,20 18,22 C19,20 20.5,18.5 22.5,18.5 C25,18.5 28,20.5 30.5,25 L30.5,28 Z" fill="#000" stroke="#000" stroke-width="3.2" stroke-linejoin="round"/></mask></defs><path d="M5.5,28 L5.5,25 C8,20.5 11,18.5 13.5,18.5 C15.5,18.5 17,20 18,22 C19,20 20.5,18.5 22.5,18.5 C25,18.5 28,20.5 30.5,25 L30.5,28 Z"/><circle cx="18" cy="18.4" r="4.6" mask="url(#ak)"/>';
// two rays (F1/F2) or four (F7/F8): hand positions inside the tablet
const TWO = [[11.5, 25], [24.5, 25]], FOUR = [[10, 24], [15, 26.5], [21, 26.5], [26, 24]];
const filled = (c, ends, id) => '<defs><mask id="' + id + '"><path d="' + T + '" fill="#fff"/><g fill="#000" stroke="#000">' + aten(18, 14.5, 3.6, ends, ends.length > 2 ? 1.7 : 2, ends.length > 2 ? 1.3 : 1.5) + '</g></mask></defs><rect width="36" height="36" fill="' + c + '" mask="url(#' + id + ')"/>';
const outlined = (c, ends) => '<path d="' + T + '" fill="none" stroke="' + c + '" stroke-width="2.2" stroke-linejoin="round"/><circle cx="18" cy="14.5" r="3.4" fill="none" stroke="' + c + '" stroke-width="1.9"/><g fill="' + c + '" stroke="' + c + '">' + aten(18, 14.5, 3.4, ends, ends.length > 2 ? 1.6 : 1.9, ends.length > 2 ? 1.3 : 1.5).replace(/^<circle[^>]*>/, '') + '</g>';
const chev = (y, w, h, rr) => { const k = rr / Math.hypot(w, h); return 'M' + r1(18 - w) + ',' + r1(y + h) + ' L' + r1(18 - w * k) + ',' + r1(y + h * k) + ' Q18,' + y + ' ' + r1(18 + w * k) + ',' + r1(y + h * k) + ' L' + r1(18 + w) + ',' + r1(y + h); };
// akhet with the sun at sy: the further up, the more of it shows above the hills
const akhetAt = (sy) => akhet.replace('cx="18" cy="18.4" r="4.6" mask', 'cx="18" cy="' + sy + '" r="4.6" mask');
const F9 = [[6.5, 25], [13.6, 27.6], [22.4, 27.6], [29.5, 25]];
const G = {
  tablet: { name: '陶板·Aten 线描', en: 'Inscribed, outline', note: 'F2 的线描版：陶板只勾轮廓，日轮是圆环，光束与手是线。最轻，适合与系统线性符号并排。',
    body: (c) => outlined(c, TWO) },
  inscribed: { name: '陶板·Aten', en: 'Inscribed', note: '实心陶板，镂空 Aten 与双手（无悬挂孔）。与 App 图标同构，最像「缩小版图标」。',
    body: (c) => filled(c, TWO, 'm2') },
  aten: { name: 'Aten', en: 'Aten', note: '只取日轮与光束末端的手。最有辨识度，菜单栏里没有第二个长这样的。',
    body: (c) => '<g fill="' + c + '" stroke="' + c + '">' + aten(18, 9.5, 6.2, [[5, 24], [9, 29], [13.5, 31.5], [18, 32.2], [22.5, 31.5], [27, 29], [31, 24]], 1.6, 1.7) + '</g>' },
  pi: { name: 'Π 铭文', en: 'Pi', note: '陶板轮廓里刻 ΠΙΝΑΞ 的首字母 Π。字母识别快，但「Π」也可能被读成数学 π。',
    body: (c) => '<path d="' + T + '" fill="none" stroke="' + c + '" stroke-width="2.4" stroke-linejoin="round"/><path d="M11.5,13.5 L24.5,13.5 M14,13.5 L14,25.5 M22,13.5 L22,25.5" fill="none" stroke="' + c + '" stroke-width="2.8" stroke-linecap="round"/>' },
  upload: { name: '陶板·上传', en: 'Upload', note: '实心陶板镂空双 ^（无悬挂孔）。直接说「这是上传工具」，也最适合做进度/状态变体。',
    body: (c) => '<defs><mask id="m5"><path d="' + T + '" fill="#fff"/><g fill="none" stroke="#000" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"><path d="' + chev(14, 5.5, 5.5, 2.6) + '"/><path d="' + chev(20.5, 5.5, 5.5, 2.6) + '"/></g></mask></defs><rect width="36" height="36" fill="' + c + '" mask="url(#m5)"/>' },
  akhet: { name: '地平线', en: 'Akhet', note: '图片框 + 地平线日出（图标下半部的 akhet）。最像「图片库」，但与系统 photo 符号接近。',
    body: (c) => '<defs><clipPath id="fr"><rect x="5.2" y="8.2" width="25.6" height="20.6" rx="3.4"/></clipPath></defs><rect x="5.2" y="8.2" width="25.6" height="20.6" rx="3.4" fill="none" stroke="' + c + '" stroke-width="2.4"/><g fill="' + c + '" clip-path="url(#fr)">' + akhet + '</g>' },
  outline4: { name: '线描·四光', en: 'Outline, four rays', note: 'F1 的线描陶板，光束增至四条。更接近图标原作的光束数量，18 pt 下手会挤成点。',
    body: (c) => outlined(c, FOUR) },
  filled4: { name: '实心·四光', en: 'Filled, four rays', note: 'F2 的实心陶板，镂空四条光束。比 F2 更「光芒四射」，但镂空细线在 16 pt 下会变糊。',
    body: (c) => filled(c, FOUR, 'm8') },
  aten4: { name: 'Aten·四光', en: 'Aten, four rays', note: 'F3 的日轮放大，光束四条、每条带手；中间两条较短，手仍比外侧两只低。',
    body: (c) => '<g fill="' + c + '" stroke="' + c + '">' + aten(18, 10, 7, F9, 2, 1.9) + '</g>' },
  aten4o: { name: 'Aten·四光 线描', en: 'Aten, four rays, outline', note: 'F9 的线描版：日轮为圆环，光束是线，手为实心小点（线的端点）。',
    body: (c) => '<circle cx="18" cy="10" r="6.6" fill="none" stroke="' + c + '" stroke-width="2"/><g fill="' + c + '" stroke="' + c + '">' + aten(18, 10, 7, F9, 2, 1.9).replace(/^<circle[^>]*>/, '') + '</g>' },
  akhetUp: { name: '地平线·上传', en: 'Akhet, upload', note: 'F6 的地平线图片框，上方加宽而扁的双 ^：「把图片往上送」。与 App 图标下半部的构图一致。',
    body: (c) => '<path d="' + chev(2.6, 8.4, 5.2, 2.8) + ' M' + chev(6.9, 8.4, 5.2, 2.8).slice(1) + '" fill="none" stroke="' + c + '" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/><defs><clipPath id="fr2"><rect x="5.6" y="15.2" width="24.8" height="17.4" rx="3.2"/></clipPath></defs><rect x="5.6" y="15.2" width="24.8" height="17.4" rx="3.2" fill="none" stroke="' + c + '" stroke-width="2.2"/><g fill="' + c + '" clip-path="url(#fr2)"><g transform="translate(18 32.6) scale(0.92 0.8) translate(-18 -28.8)">' + akhetAt(16.4) + '</g></g>' }
};
const svg = (inner) => 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36">' + inner + '</svg>');

module.exports = { G, svg };
