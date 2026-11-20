// Renders the Pinax app icon as an SVG string from a parameter object.
// This is the same code as the parametric tuner board (E) on the Design canvas,
// so values copied from the board's Tweaks drop straight into pinax.json.
// Regenerate the icon with:
//     node Design/AppIcon/generate-svg.js && Scripts/make-app-icon.sh
module.exports = function render(p) {
const v = (k, d) => (p[k] ?? d);
const on = (k) => v(k, true) !== false;
const f = (n) => Math.round(n * 10) / 10;
const clayHi = v('clayHi', '#E08A55'), clayLo = v('clayLo', '#B5532C'), ink = v('ink', '#1F130D');
// pigments from Egyptian wall painting, muted; the two 多色 schemes colour each part of a group differently
const B = '#2F5E9E', K = '#221A16', G = '#3E7A62', T = '#4A8C88', Y = '#D9AE45', W = '#F1E7D3', O = '#B8862E', R = '#8A2E1C';
const PIG = {'白彩': W, '埃及蓝彩': B, '孔雀绿彩': G, '绿松石彩': T, '雌黄彩': Y, '赭黄彩': O, '赭红彩': R, '炭黑彩': K};
const MULTI = {'多色彩': {text: [B, K, G, B, K], disc: Y, ray: K, hand: B, chev: [B, G], frame: B, hill: G, sun: Y},
'多色彩·浅': {text: [W, T, W, Y, W], disc: Y, ray: W, hand: T, chev: [W, T], frame: W, hill: T, sun: Y},
'多色彩·暖': {text: [K, R, K, O, K], disc: Y, ray: R, hand: K, chev: [R, O], frame: K, hill: R, sun: Y}};
const pal = (k, part, i) => { const s = v(k, '黑绘'); if (PIG[s]) return PIG[s]; const m = MULTI[s]; if (!m) return ink; const c = m[part]; return Array.isArray(c) ? c[(i || 0) % c.length] : c; };
const CLOTH = {'石板蓝':['#3A4250','#232933','#12161C'],'午夜蓝':['#2C3A58','#1A2440','#0B1122'],'普鲁士蓝':['#2A4556','#183040','#0A1822'],'博物馆绿':['#34453C','#1F2B25','#0F1612'],'深红':['#6A1E26','#461117','#1F0508'],'波尔多酒红':['#4A2A30','#2E181D','#16090C'],'茄紫':['#3E3048','#261C2E','#120C16'],'暖黑':['#3A302A','#1E1814','#0C0907'],'炭灰':['#44464A','#2A2B2E','#141517'],
'原色亚麻':['#E4D8C0','#C9BA9A','#9C8C6C'],'象牙':['#F4EFE4','#DED6C6','#B3AA98'],'燕麦':['#EDE6D8','#D2C8B6','#A89A84'],'石灰白':['#E8E5DE','#CDC8BE','#9F9A90'],'砂岩':['#E8D5BD','#CDB494','#9E8567'],'鸽灰':['#D4D2CD','#B2B0AB','#85837E'],'雾蓝':['#DAE0E5','#B9C3CB','#8A959F'],'鼠尾草':['#D8DED0','#B8C0AE','#8A9380'],'灰粉':['#E9DAD5','#D0BBB4','#A38B84']};
const LIGHT = ['原色亚麻','象牙','燕麦','石灰白','砂岩','鸽灰','雾蓝','鼠尾草','灰粉'];
const cloth = v('cloth', '燕麦'), [bgTop, bgMid, bgEdge] = CLOTH[cloth] || CLOTH['燕麦'];
const light = LIGHT.includes(cloth), tc = light ? '0' : '1', tcol = light ? '#000' : '#fff';
const weave = v('weave', '波纹绸'), tex = v('texture', 0.6);
const g = (n) => Math.round(n * 1000) / 1000;
const nz = (id, freq, a, b, extra) => '<feTurbulence type="' + (extra || 'fractalNoise') + '" baseFrequency="' + freq + '" numOctaves="3" seed="' + id + '" result="n' + id + '"/><feColorMatrix in="n' + id + '" values="0 0 0 0 ' + tc + '  0 0 0 0 ' + tc + '  0 0 0 0 ' + tc + '  0 0 0 ' + g(a * tex) + ' ' + b + '" result="m' + id + '"/>';
// lit(): noise as a height map, lit from the upper left; brighter than flat adds white, darker adds black
const lit = (id, freq, oct, ss, a, blur) => {
const pv = g(Math.sin(40 * Math.PI / 180)), k = g(a * tex);
return '<feTurbulence type="fractalNoise" baseFrequency="' + freq + '" numOctaves="' + oct + '" seed="' + id + '" result="t' + id + '"/>' +
(blur ? '<feGaussianBlur in="t' + id + '" stdDeviation="' + blur + '" result="t' + id + '"/>' : '') +
'<feDiffuseLighting in="t' + id + '" surfaceScale="' + ss + '" diffuseConstant="1" lighting-color="#fff" result="l' + id + '"><feDistantLight azimuth="235" elevation="40"/></feDiffuseLighting>' +
'<feColorMatrix in="l' + id + '" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  ' + k + ' 0 0 0 ' + g(-k * pv) + '" result="h' + id + '"/>' +
'<feColorMatrix in="l' + id + '" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  ' + (-k) + ' 0 0 0 ' + g(k * pv) + '" result="d' + id + '"/>'; };
const mg = (...ids) => '<feMerge result="mx">' + ids.map((i) => '<feMergeNode in="' + i + '"/>').join('') + '</feMerge>';
const WF = {
'亚麻': '<feTurbulence type="fractalNoise" baseFrequency="0.9 0.012" numOctaves="2" seed="3" result="h"/><feTurbulence type="fractalNoise" baseFrequency="0.012 0.9" numOctaves="2" seed="5" result="v"/><feBlend in="h" in2="v" mode="multiply" result="w"/><feColorMatrix in="w" values="0 0 0 0 ' + tc + '  0 0 0 0 ' + tc + '  0 0 0 0 ' + tc + '  0 0 0 ' + g(0.16 * tex) + ' -0.02" result="mx"/>',
// crushed velvet: large soft pile folds catch the light, dense fine pile underneath
'丝绒': lit(61, '0.004 0.009', 4, 12, 1.1, 3) + lit(62, '1.4', 1, 0.6, 0.35) + mg('h61', 'd61', 'h62', 'd62'),
// suede: short brushed nap in one direction, fine speckle, faint mottling
'麂皮': lit(71, '1.1 0.5', 2, 0.9, 0.7) + lit(72, '0.015', 3, 4, 0.3, 2) + nz(73, '2.2', 0.1, -0.03) + mg('h71', 'd71', 'h72', 'd72', 'm73'),
// satin: long fluid folds, smooth surface, strong sheen
'缎面': lit(81, '0.0018 0.005', 2, 12, 1.6, 10) + mg('h81', 'd81'),
// raw silk (shantung): fine weave with irregular horizontal slubs
'生丝': '<feTurbulence type="fractalNoise" baseFrequency="0.015 0.7" numOctaves="2" seed="91" result="s"/><feColorMatrix in="s" values="0 0 0 0 ' + tc + '  0 0 0 0 ' + tc + '  0 0 0 0 ' + tc + '  0 0 0 ' + g(3 * tex) + ' ' + g(-1.9 * tex) + '" result="m91"/>' + nz(92, '0.7 0.9', 0.1, -0.02) + lit(93, '0.003 0.01', 2, 10, 0.6, 5) + mg('h93', 'd93', 'm92', 'm91'),
// wool baize: dense short felted fibres, no weave visible
'呢绒': lit(95, '0.9', 3, 0.9, 0.7) + nz(96, '0.02', 0.08, -0.02) + mg('h95', 'd95', 'm96'),
'波纹绸': nz(31, '0.0025 0.02', 0.3, -0.06, 'turbulence') + nz(32, '0.02 0.6', 0.08, -0.01) + mg('m31', 'm32'),
'罗缎': nz(41, '0.002 0.3', 0.2, -0.05) + nz(42, '0.9', 0.06, -0.01) + mg('m41', 'm42')};
const PAT = {
'斜纹': '<pattern id="pt" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(-35)"><rect width="6" height="2" fill="' + tcol + '"/></pattern>',
'人字纹': '<pattern id="pt" width="28" height="9" patternUnits="userSpaceOnUse"><path d="M0,11 L14,-3 M0,2 L5,-3 M9,11 L14,6 M14,-3 L28,11 M14,6 L19,11 M23,-3 L28,2" stroke="' + tcol + '" stroke-width="2.6" fill="none"/></pattern>',
// damask: tone-on-tone ogee lattice with a small four-petal flower, satin sheen over it
'锦缎': '<pattern id="pt" width="64" height="80" patternUnits="userSpaceOnUse"><path d="M32,0 C52,14 52,26 32,40 C12,54 12,66 32,80 M32,0 C12,14 12,26 32,40 C52,54 52,66 32,80" stroke="' + tcol + '" stroke-width="3" fill="none"/><g fill="' + tcol + '"><ellipse cx="32" cy="14" rx="3" ry="6"/><ellipse cx="32" cy="26" rx="3" ry="6"/><ellipse cx="26" cy="20" rx="6" ry="3"/><ellipse cx="38" cy="20" rx="6" ry="3"/><circle cx="0" cy="60" r="4"/><circle cx="64" cy="60" r="4"/></g></pattern>',
// quilted: diamond quilting, each cell softly pillowed
'菱格绗缝': '<pattern id="pt" width="44" height="44" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="44" height="44" fill="none" stroke="' + tcol + '" stroke-width="3"/></pattern>'};
const PATF = {'锦缎': lit(97, '0.002 0.006', 2, 16, 0.9, 6) + mg('h97', 'd97'), '菱格绗缝': lit(98, '0.02', 2, 8, 0.5, 2) + nz(99, '0.9', 0.06, -0.02) + mg('h98', 'd98', 'm99')};
const patOp = {'斜纹': 0.05, '人字纹': 0.05, '锦缎': 0.09, '菱格绗缝': 0.16};
const FL = '<filter id="tx" x="0" y="0" width="1" height="1" color-interpolation-filters="sRGB">';
const RECT = '<rect x="100" y="100" width="824" height="824" ';
let wdef = '', wbody = '';
if (WF[weave]) { wdef = FL + WF[weave] + '<feComposite in="mx" in2="SourceGraphic" operator="in"/></filter>'; wbody = RECT + 'fill="#fff" filter="url(#tx)"/>'; }
if (PAT[weave]) { wdef = PAT[weave] + FL + (PATF[weave] || nz(51, '0.8', 0.1, -0.02) + mg('m51')) + '<feComposite in="mx" in2="SourceGraphic" operator="in"/></filter>'; wbody = RECT + 'fill="url(#pt)" opacity="' + g(patOp[weave] * tex) + '"/>' + RECT + 'fill="#fff" filter="url(#tx)"/>'; }
const facet = v('facet', 1), wear = v('wear', true);
const letterScale = v('letterScale', 1.16), letterY = v('letterY', 300);
const DX = 512, DY = v('discY', 428), DR = v('discR', 52);
const rays = v('rays', 3), rayStart = v('rayStart', 38), rayStep = v('rayStep', 12), rayW = v('rayW', 9);
const chevY = v('chevY', 536), chevGap = v('chevGap', 52), chevHalf = v('chevHalf', 38), chevW = v('chevW', 18);
const fy0 = v('frameY', 664), fw = v('frameW', 320), fh = v('frameH', 200), akS = v('akhetS', 108);
const fx0 = DX - fw / 2, fy1 = fy0 + fh, hi = '#F3B98E';
const sq = [];
for (let i = 0; i < 240; i++) {
const t = 2 * Math.PI * i / 240, c = Math.cos(t), s = Math.sin(t);
sq.push(f(512 + 412 * Math.sign(c) * Math.pow(Math.abs(c), 0.4)) + ',' + f(512 + 412 * Math.sign(s) * Math.pow(Math.abs(s), 0.4)));
}
const SQ = 'M' + sq.join(' L') + 'Z';
const tab = [[206,222],[318,198],[468,210],[604,196],[684,208],[724,248],[786,252],[830,308],[844,452],[828,586],[846,742],[840,1100],[194,1100],[184,748],[204,566],[186,404]];
const TAB = 'M' + tab.map((q) => q.join(',')).join(' L') + 'Z';
const facets = [
[[[724,248],[786,252],[830,308],[844,452],[760,470],[704,330]], '#000', 0.07],
[[[186,404],[206,222],[318,198],[300,330]], '#fff', 0.06],
[[[204,566],[184,748],[194,1100],[290,1100],[300,700]], '#000', 0.06],
[[[844,452],[828,586],[846,742],[840,1100],[740,1100],[770,640],[760,470]], '#000', 0.1]];
const cracks = ['M704,330 L760,470 L770,640 L740,1100', 'M318,198 L300,330 L186,404', 'M204,566 L300,700 L290,1100'];
const st = (d, w, c) => '<path d="' + d + '" fill="none" stroke="' + (c || ink) + '" stroke-width="' + w + '" stroke-linecap="round" stroke-linejoin="round"/>';
const top = 256, bot = 322, mid = 289;
const track = v('letterTrack', 1), lw = v('letterW', 17), gap = 38 * track;
let x = 512 - (198 + 4 * gap) / 2 + v('letterX', 0); const L = [];
L.push('M' + x + ',' + bot + ' L' + (x + 1) + ',' + top + ' L' + (x + 48) + ',' + (top + 1) + ' L' + (x + 47) + ',' + (bot - 10)); x += 48 + gap;
L.push('M' + x + ',' + top + ' L' + x + ',' + bot); x += gap;
L.push('M' + x + ',' + bot + ' L' + x + ',' + top + ' L' + (x + 46) + ',' + bot + ' L' + (x + 46) + ',' + top); x += 46 + gap;
L.push('M' + x + ',' + bot + ' L' + (x + 27) + ',' + top + ' L' + (x + 54) + ',' + bot + ' M' + (x + 11) + ',' + (bot - 24) + ' L' + (x + 43) + ',' + (bot - 24)); x += 54 + gap;
L.push('M' + x + ',' + top + ' L' + (x + 50) + ',' + top + ' M' + (x + 9) + ',' + mid + ' L' + (x + 41) + ',' + mid + ' M' + x + ',' + bot + ' L' + (x + 50) + ',' + bot);
const letters = '<g transform="translate(0 ' + (letterY - 300) + ') translate(512 300) scale(' + letterScale + ') translate(-512 -300)">' + L.map((d, i) => st(d, lw, pal('finText', 'text', i))).join('') + '</g>';
const akhet = (cx, cy, s, hc, sc) =>
'<path d="M' + f(cx - 1.3 * s) + ',' + cy + ' C' + f(cx - 1.15 * s) + ',' + f(cy - 0.3 * s) + ' ' + f(cx - 0.75 * s) + ',' + f(cy - 0.62 * s) + ' ' + f(cx - 0.5 * s) + ',' + f(cy - 0.62 * s) +
' C' + f(cx - 0.25 * s) + ',' + f(cy - 0.62 * s) + ' ' + f(cx - 0.1 * s) + ',' + f(cy - 0.3 * s) + ' ' + cx + ',' + f(cy - 0.2 * s) +
' C' + f(cx + 0.1 * s) + ',' + f(cy - 0.3 * s) + ' ' + f(cx + 0.25 * s) + ',' + f(cy - 0.62 * s) + ' ' + f(cx + 0.5 * s) + ',' + f(cy - 0.62 * s) +
' C' + f(cx + 0.75 * s) + ',' + f(cy - 0.62 * s) + ' ' + f(cx + 1.15 * s) + ',' + f(cy - 0.3 * s) + ' ' + f(cx + 1.3 * s) + ',' + cy + ' Z" fill="' + hc + '"/>' +
'<circle cx="' + cx + '" cy="' + f(cy - 1.02 * s) + '" r="' + f(0.2 * s) + '" fill="' + sc + '"/>';
// surface finishes: each group is drawn as a plain shape, a filter rebuilds its look from the shape's alpha
const FIN = ['黑绘", "刻划", "凹浮雕", "浅浮雕", "白彩", "埃及蓝彩", "孔雀绿彩", "绿松石彩", "雌黄彩", "赭黄彩", "赭红彩", "炭黑彩", "多色彩", "多色彩·浅", "多色彩·暖", "金箔", "平涂'];
const rough = v('rough', 2.5);
const FU = (id) => '<filter id="' + id + '" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1100" color-interpolation-filters="sRGB">';
const A = (r) => '<feTurbulence type="fractalNoise" baseFrequency="0.55" numOctaves="2" seed="7" result="rn"/><feDisplacementMap in="SourceAlpha" in2="rn" scale="' + r + '" xChannelSelector="R" yChannelSelector="G" result="A"/>';
const col = (c, o, inp, res) => '<feFlood flood-color="' + c + '" flood-opacity="' + o + '"/><feComposite in2="' + inp + '" operator="in" result="' + res + '"/>';
const edge = (dx, dy, b, c, o, res) => '<feOffset in="A" dx="' + dx + '" dy="' + dy + '" result="' + res + 'o"/><feComposite in="A" in2="' + res + 'o" operator="out" result="' + res + 'e"/>' +
(b ? '<feGaussianBlur in="' + res + 'e" stdDeviation="' + b + '" result="' + res + 'b"/><feComposite in="' + res + 'b" in2="A" operator="in" result="' + res + 'e"/>' : '') + col(c, o, res + 'e', res);
const sheen = (exp, k, res) => '<feGaussianBlur in="A" stdDeviation="2.5" result="Ab"/><feSpecularLighting in="Ab" surfaceScale="4" specularConstant="0.9" specularExponent="' + exp + '" lighting-color="#fff" result="sp"><feDistantLight azimuth="225" elevation="45"/></feSpecularLighting><feComposite in="sp" in2="A" operator="in" result="sp2"/><feComponentTransfer in="sp2" result="' + res + '"><feFuncA type="linear" slope="' + k + '"/></feComponentTransfer>';
const chalk = (inp, res) => '<feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="13" result="cn"/><feColorMatrix in="cn" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1.4 0.2" result="cm"/>' +
'<feTurbulence type="fractalNoise" baseFrequency="0.045" numOctaves="3" seed="17" result="fn"/><feColorMatrix in="fn" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -18 12.4" result="fm"/>' +
'<feComposite in="' + inp + '" in2="cm" operator="in" result="ch1"/><feComposite in="ch1" in2="fm" operator="in" result="' + res + '"/>';
const fm = (...ids) => '<feMerge>' + ids.map((i) => '<feMergeNode in="' + i + '"/>').join('') + '</feMerge>';
const FX = {
'黑绘': (id) => FU(id) + A(rough) + col(ink, 1, 'A', 'b') + sheen(18, 0.35, 'sh') + fm('b', 'sh') + '</filter>',
'刻划': (id) => FU(id) + A(rough * 0.5) + col('#7A3014', 1, 'A', 'b') + edge(3, 3, 0.8, '#2A0E05', 0.85, 's') + edge(-2, -2, 0.6, hi, 0.7, 'h') + fm('b', 's', 'h') + '</filter>',
'凹浮雕': (id) => FU(id) + A(rough * 0.4) + col(clayLo, 1, 'A', 'b') + edge(6, 6, 2.5, '#3A1508', 0.75, 's') + edge(-3, -3, 1.5, hi, 0.6, 'h') + fm('b', 's', 'h') + '</filter>',
'浅浮雕': (id) => FU(id) + A(rough * 0.4) + '<feOffset in="A" dx="5" dy="6" result="d0"/><feGaussianBlur in="d0" stdDeviation="3" result="d1"/>' + col('#3A1508', 0.55, 'd1', 'ds') +
col(clayHi, 1, 'A', 'b') + edge(3, 3, 1.5, '#FFF3E6', 0.6, 'h') + edge(-3, -3, 1.5, '#5A2412', 0.55, 's') + fm('ds', 'b', 'h', 's') + '</filter>',
'金箔': (id) => FU(id) + A(rough * 0.5) + col('#A9821F', 1, 'A', 'b') + '<feTurbulence type="fractalNoise" baseFrequency="1.1" numOctaves="2" seed="21" result="gn"/><feColorMatrix in="gn" values="0 0 0 0 1  0 0 0 0 0.93  0 0 0 0 0.7  0 0 0 1.6 -0.7" result="gm"/><feComposite in="gm" in2="A" operator="in" result="sp0"/>' +
edge(-3, -3, 1.5, '#4A2E08', 0.8, 's') + edge(3, 3, 1, '#FFF1C0', 0.75, 'h') + sheen(10, 1, 'sh') + fm('b', 'sp0', 's', 'h', 'sh') + '</filter>'};
// painted finishes keep each shape's own colour: roughen the edges, then chalky texture and flaking
const PAINT = (id) => FU(id) + '<feTurbulence type="fractalNoise" baseFrequency="0.55" numOctaves="2" seed="7" result="rn"/><feDisplacementMap in="SourceGraphic" in2="rn" scale="' + rough + '" xChannelSelector="R" yChannelSelector="G" result="G0"/>' + chalk('G0', 'b') + fm('b') + '</filter>';
Object.keys(PIG).concat(Object.keys(MULTI)).forEach((k) => { FX[k] = PAINT; });
const fin = (k, d) => { const s = v(k, d); return FX[s] || s === '平涂' ? s : d; };
const sText = fin('finText', '黑绘'), sAten = fin('finAten', '黑绘'), sChev = fin('finChev', '黑绘'), sFrame = fin('finFrame', '黑绘');
const fdefs = [['fT', sText], ['fA', sAten], ['fC', sChev], ['fF', sFrame]].map(([id, s]) => (FX[s] ? FX[s](id) : '')).join('');
const wrap = (id, s, body) => (FX[s] ? '<g filter="url(#' + id + ')">' + body + '</g>' : '<g>' + body + '</g>');
const discHi = v('discHi', '刻线');
const pt = (deg, r) => f(DX + Math.cos(deg * Math.PI / 180) * r) + ',' + f(DY + Math.sin(deg * Math.PI / 180) * r);
let aten = '<circle cx="' + DX + '" cy="' + DY + '" r="' + DR + '" fill="' + pal('finAten', 'disc') + '"/>', dhl = '';
const painted = sAten === '黑绘' || sAten === '平涂';
if (painted && discHi === '刻线') dhl += '<path d="M' + pt(200, DR * 0.68) + ' A' + f(DR * 0.68) + ',' + f(DR * 0.68) + ' 0 0 1 ' + pt(250, DR * 0.68) + '" fill="none" stroke="' + clayHi + '" stroke-width="4" stroke-linecap="round" opacity="0.8"/>';
if (painted && discHi === '原版') dhl += '<path d="M' + f(DX - DR * 0.85) + ',' + f(DY - DR * 0.38) + ' A' + f(DR * 0.92) + ',' + f(DR * 0.92) + ' 0 0 1 ' + f(DX + DR * 0.85) + ',' + f(DY - DR * 0.38) + '" fill="none" stroke="' + clayHi + '" stroke-width="5"/>';
const angs = [];
for (let i = 0; i < rays; i++) { const a = rayStart + i * rayStep; angs.push(a, 180 - a); }
for (const ad of angs) {
// hands keep their horizontal positions (as laid out for the default geometry); moving the frame only stretches the rays vertically
const a = ad * Math.PI / 180, r0 = DR + 14, ex = DX + v('raySpread', 1) * 196 * Math.cos(a) / Math.sin(a), ey = fy0 - 40;
if (ey - DY <= r0) continue;
const b = Math.atan2(ey - DY, ex - DX), sx = DX + Math.cos(b) * r0, sy = DY + Math.sin(b) * r0, rot = f(b * 180 / Math.PI - 90);
aten += st('M' + f(sx) + ',' + f(sy) + ' L' + f(ex) + ',' + f(ey), rayW, pal('finAten', 'ray'));
aten += '<ellipse cx="' + f(ex) + '" cy="' + f(ey + 10) + '" rx="9" ry="13" fill="' + pal('finAten', 'hand') + '" transform="rotate(' + rot + ' ' + f(ex) + ' ' + f(ey + 10) + ')"/>';
}
const ch = chevHalf * 28 / 38;
const chev = [chevY, chevY + chevGap].map((y, i) => st('M' + (DX - chevHalf) + ',' + f(y + ch) + ' L' + DX + ',' + y + ' L' + (DX + chevHalf) + ',' + f(y + ch), chevW, pal('finChev', 'chev', i))).join('');
const frameBg = '<rect x="' + fx0 + '" y="' + fy0 + '" width="' + fw + '" height="' + fh + '" rx="14" fill="' + clayHi + '"/>';
const frame = '<rect x="' + fx0 + '" y="' + fy0 + '" width="' + fw + '" height="' + fh + '" rx="14" fill="none" stroke="' + pal('finFrame', 'frame') + '" stroke-width="18"/>' + akhet(DX, fy1 - 9, akS, pal('finFrame', 'hill'), pal('finFrame', 'sun'));
// suspension hole: votive pinakes were hung by a hole near the top
const hole = !on('hole') ? '' : '<circle cx="258" cy="262" r="14" fill="#5A2412"/><path d="M246,256 A14,14 0 0 1 271,258" fill="none" stroke="#2A0F06" stroke-width="5"/>';
const fac = facets.map(([pts, c, o]) => '<polygon points="' + pts.map((q) => q.join(',')).join(' ') + '" fill="' + c + '" opacity="' + Math.min(1, o * facet) + '"/>').join('');
const crk = cracks.map((d) => '<path d="' + d + '" fill="none" stroke="#6E2A12" stroke-width="3" opacity="' + Math.min(1, 0.55 * facet) + '"/><path d="' + d + '" transform="translate(2,2)" fill="none" stroke="' + hi + '" stroke-width="1.5" opacity="' + Math.min(1, 0.35 * facet) + '"/>').join('');
const art = (on('showFrame') ? frameBg : '') + (on('showText') ? wrap('fT', sText, letters) : '') + (on('showAten') ? wrap('fA', sAten, aten) + dhl : '') + (on('showChev') ? wrap('fC', sChev, chev) : '') + (on('showFrame') ? wrap('fF', sFrame, frame) : '');
// museum spotlight: darkens the cloth away from a pool of light on the tablet, optional warm wash and a visible beam from above
const spot = v('spot', '关'), spX = v('spotX', 512), spY = v('spotY', 440), spR = v('spotR', 440), spD = v('spotDark', 0.6), spW = v('spotWarm', 0.25);
let spDefs = '', spBody = '';
if (spot !== '关') {
spDefs = '<radialGradient id="spd" gradientUnits="userSpaceOnUse" cx="' + spX + '" cy="' + spY + '" r="' + spR + '" gradientTransform="translate(' + spX + ' ' + spY + ') scale(1 1.2) translate(' + (-spX) + ' ' + (-spY) + ')"><stop offset="0" stop-color="#000" stop-opacity="0"/><stop offset="0.38" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="' + spD + '"/></radialGradient>' +
'<radialGradient id="spw" gradientUnits="userSpaceOnUse" cx="' + spX + '" cy="' + (spY - spR * 0.15) + '" r="' + f(spR * 0.75) + '"><stop offset="0" stop-color="#FFE6C0" stop-opacity="' + spW + '"/><stop offset="1" stop-color="#FFE6C0" stop-opacity="0"/></radialGradient>' +
'<linearGradient id="spb" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFF1D8" stop-opacity="' + g(spW * 0.9) + '"/><stop offset="1" stop-color="#FFF1D8" stop-opacity="0"/></linearGradient><filter id="spf" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="24"/></filter>';
spBody = (spot === '舞台' ? '<path d="M' + (spX - 50) + ',60 L' + (spX + 50) + ',60 L' + f(spX + spR * 0.85) + ',' + f(spY + spR * 0.35) + ' L' + f(spX - spR * 0.85) + ',' + f(spY + spR * 0.35) + 'Z" fill="url(#spb)" filter="url(#spf)" style="mix-blend-mode:screen"/>' : '') +
'<rect x="100" y="100" width="824" height="824" fill="url(#spw)" style="mix-blend-mode:screen"/><rect x="100" y="100" width="824" height="824" fill="url(#spd)"/>';
}
const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>' +
'<radialGradient id="spot" cx="0.5" cy="0.18" r="0.9"><stop offset="0" stop-color="' + bgTop + '"/><stop offset="0.55" stop-color="' + bgMid + '"/><stop offset="1" stop-color="' + bgEdge + '"/></radialGradient>' +
wdef + fdefs + spDefs +
'<linearGradient id="clay" x1="0" y1="0" x2="0.5" y2="1"><stop offset="0" stop-color="' + clayHi + '"/><stop offset="1" stop-color="' + clayLo + '"/></linearGradient>' +
'<filter id="grain" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="4"/><feColorMatrix values="0 0 0 0 0.3  0 0 0 0 0.12  0 0 0 0 0.05  0 0 0 0.45 -0.1"/><feComposite in2="SourceGraphic" operator="in"/></filter>' +
'<filter id="wear"><feTurbulence type="fractalNoise" baseFrequency="0.07" numOctaves="3" seed="9" result="n"/><feColorMatrix in="n" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 -12 10.6" result="m"/><feComposite in="SourceGraphic" in2="m" operator="in"/></filter>' +
'<filter id="drop" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="10" dy="18" stdDeviation="16" flood-color="#000" flood-opacity="0.6"/></filter>' +
'<clipPath id="sq"><path d="' + SQ + '"/></clipPath><clipPath id="tc"><path d="' + TAB + '"/></clipPath></defs>' +
'<path d="' + SQ + '" fill="url(#spot)"/>' +
'<g clip-path="url(#sq)">' + wbody +
'<g transform="translate(' + v('tabX', 0) + ' ' + v('tabY', 0) + ') translate(512 512) scale(' + v('tabScale', 1) + ') translate(-512 -512)"><g filter="url(#drop)"><path d="' + TAB + '" transform="translate(12,14)" fill="#7E3519" stroke="#7E3519" stroke-width="4" stroke-linejoin="round"/><path d="' + TAB + '" fill="url(#clay)" stroke="url(#clay)" stroke-width="4" stroke-linejoin="round"/></g>' +
'<g clip-path="url(#tc)"><rect x="150" y="150" width="760" height="900" fill="#fff" filter="url(#grain)"/>' + fac + crk +
(wear ? '<g filter="url(#wear)">' + art + '</g>' : '<g>' + art + '</g>') + hole +
'<path d="' + TAB + '" fill="none" stroke="' + hi + '" stroke-width="3" opacity="0.5" transform="translate(-2,-2)" stroke-linejoin="round"/></g></g>' + spBody + '</g>' +
'<path d="' + SQ + '" fill="none" stroke="#fff" stroke-opacity="0.10" stroke-width="3"/></svg>';
return svg;
};
