package main

import "core:math"

// ─── 解像度定義 ────────────────────────────────────────────────────────────
// CSS 側でフルスクリーンに拡大するため内部解像度は控えめに保つ
WIDTH :: 512
HEIGHT :: 384
NOISE_DIM :: 64 // 2のべき乗である必要がある

// JS 側が解像度を問い合わせられるようにエクスポート
// (Odin側の定数を単一の真実の情報源にする)
@(export)
get_width :: proc "contextless" () -> i32 {return WIDTH}

@(export)
get_height :: proc "contextless" () -> i32 {return HEIGHT}

// ─── 高速三角関数 ──────────────────────────────────────────────────────────
// freestanding_wasm32 では core:math の sin/cos は外部関数 (env.sinf/env.cosf)
// に依存し、ピクセル毎に呼ぶとFFI境界のオーバーヘッドで大きく重くなる。
// ここでは自己完結のポリノミアル近似 (最大誤差 ~0.001) を使い、
// ホスト関数への依存を完全に無くして軽量化する。
fast_sin :: proc "contextless" (x: f32) -> f32 {
	PI :: 3.14159265358979
	TAU :: 6.28318530717958
	xr := x - TAU * math.floor((x + PI) * (1.0 / TAU))
	B :: 4.0 / PI
	C :: -4.0 / (PI * PI)
	ay := xr < 0 ? -xr : xr
	y := B * xr + C * xr * ay
	P :: 0.225
	ay = y < 0 ? -y : y
	return P * (y * ay - y) + y
}

fast_cos :: proc "contextless" (x: f32) -> f32 {
	PI :: 3.14159265358979
	return fast_sin(x + PI * 0.5)
}

// ─── 共有バッファ ──────────────────────────────────────────────────────────
pixel_buffer: [WIDTH * HEIGHT * 4]u8
noise_tex: [NOISE_DIM * NOISE_DIM]f32

// JS 側にバッファ先頭ポインタを渡す
@(export)
get_buffer_ptr :: proc "contextless" () -> ^u8 {
	return &pixel_buffer[0]
}

// ─── ユーティリティ ────────────────────────────────────────────────────────

lerp :: proc "contextless" (a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

clamp01 :: proc "contextless" (v: f32) -> f32 {
	if v < 0.0 do return 0.0
	if v > 1.0 do return 1.0
	return v
}

smoothstep :: proc "contextless" (edge0, edge1, x: f32) -> f32 {
	t := clamp01((x - edge0) / (edge1 - edge0))
	return t * t * (3.0 - 2.0 * t)
}

// ─── ノイズテクスチャ ──────────────────────────────────────────────────────

_hash :: proc "contextless" (px, py: i32) -> f32 {
	n := u32(px * 157 + py * 113)
	n = (n << 13) ~ n
	n = n * (n * n * 15731 + 789221) + 1376312589
	n = n & 0x7fffffff
	return f32(n) / f32(0x7fffffff)
}

@(export)
init_noise :: proc "contextless" () {
	for y in 0 ..< NOISE_DIM {
		for x in 0 ..< NOISE_DIM {
			noise_tex[y * NOISE_DIM + x] = _hash(i32(x), i32(y))
		}
	}
}

// バイリニア補間付きノイズサンプラ
sample_noise :: proc "contextless" (x, y: f32) -> f32 {
	ix := i32(math.floor(x))
	iy := i32(math.floor(y))
	fx := x - f32(ix)
	fy := y - f32(iy)
	sx := fx * fx * (3.0 - 2.0 * fx) // スムーズステップ
	sy := fy * fy * (3.0 - 2.0 * fy)
	mask: i32 = NOISE_DIM - 1

	ix = ix & mask
	iy = iy & mask
	ix1 := (ix + 1) & mask
	iy1 := (iy + 1) & mask

	v00 := noise_tex[iy * NOISE_DIM + ix]
	v10 := noise_tex[iy * NOISE_DIM + ix1]
	v01 := noise_tex[iy1 * NOISE_DIM + ix]
	v11 := noise_tex[iy1 * NOISE_DIM + ix1]
	return v00 + (v10 - v00) * sx + ((v01 - v00) + (v00 - v10 - v01 + v11) * sx) * sy
}

// フラクタル・ブラウン運動（多オクターブノイズ）
fbm :: proc "contextless" (x, y: f32, octaves: i32) -> f32 {
	v: f32 = 0.0
	amp: f32 = 0.5
	freq: f32 = 1.0
	m: f32 = 0.0
	for _ in 0 ..< octaves {
		v += amp * sample_noise(x * freq, y * freq)
		m += amp
		amp *= 0.5
		freq *= 2.0
	}
	return v / m
}

// ─── メインレンダラ ────────────────────────────────────────────────────────
// time: 経過秒数（JS の requestAnimationFrame timestamp / 1000）
@(export)
render_frame :: proc "contextless" (time: f32) {

	// 太陽の角度（ゆっくりサイクル: 約 210 秒で 1 周）
	sun_angle := time * 0.03
	sun_y_sin := fast_sin(sun_angle) // -1 〜 +1  (負 = 夜, 正 = 昼)
	sun_x_cos := fast_cos(sun_angle)

	// 正規化した太陽高度: 0 = 真夜中, 1 = 正午
	day_t := clamp01(sun_y_sin * 0.5 + 0.5)

	// 夕暮れ係数 (日の出・日没付近で 1)
	sunset_t := 1.0 - math.abs(sun_y_sin) * 2.5
	if sunset_t < 0.0 do sunset_t = 0.0

	for y in 0 ..< HEIGHT {
		is_water := y > HEIGHT / 2

		// 水面は空を上下反転してサンプリング
		ry := is_water ? HEIGHT - y : y
		// uy: 0(地平線) → 1(天頂 or 水底)
		uy := f32(ry) / f32(HEIGHT / 2)

		for x in 0 ..< WIDTH {
			ux := f32(x) / f32(WIDTH)

			// ── 空のグラデーション ──────────────────────────────────────
			// 夜: Tokyo Night (#1a1b26 → #24283b)
			// 昼: 青空 (#1a6fd0 → #5cb8ff)
			// 地平線付近の暖色 (日の出/日没)

			// 天頂色
			sky_top_r := lerp(10.0, 40.0, day_t)
			sky_top_g := lerp(12.0, 120.0, day_t)
			sky_top_b := lerp(35.0, 220.0, day_t)

			// 地平線色（昼は明るいシアン、夜は暗め）
			sky_bot_r := lerp(26.0, 170.0, day_t)
			sky_bot_g := lerp(27.0, 210.0, day_t)
			sky_bot_b := lerp(50.0, 252.0, day_t)

			// 日の出・日没の暖色オーバーレイ
			if sunset_t > 0.01 {
				sunset_factor := sunset_t * smoothstep(0.0, 0.3, 1.0 - uy)
				sky_bot_r = lerp(sky_bot_r, 255.0, sunset_factor * 0.7)
				sky_bot_g = lerp(sky_bot_g, 140.0, sunset_factor * 0.5)
				sky_bot_b = lerp(sky_bot_b, 60.0, sunset_factor * 0.6)
			}

			sr := lerp(sky_top_r, sky_bot_r, uy)
			sg := lerp(sky_top_g, sky_bot_g, uy)
			sb := lerp(sky_top_b, sky_bot_b, uy)

			// ── 太陽 ─────────────────────────────────────────────────────
			sun_px := (sun_x_cos * 0.4 + 0.5) // 0.1 〜 0.9
			sun_py := 0.90 - day_t * 0.80 // 昼は高く

			dx := ux - sun_px
			dy := uy - sun_py
			sun_dist := math.sqrt(dx * dx + dy * dy)

			// 太陽が地平線より上にあるときだけ描画
			if sun_y_sin > -0.05 {
				// コア（強い白）
				if sun_dist < 0.05 {
					b := 1.0 - sun_dist / 0.05
					sr = lerp(sr, 255.0, b * 0.92)
					sg = lerp(sg, 245.0, b * 0.92)
					sb = lerp(sb, 200.0, b * 0.85)
				}
				// グロー
				if sun_dist < 0.3 {
					g := 1.0 - sun_dist / 0.3
					g = g * g * 0.28 * day_t
					sr = lerp(sr, 255.0, g)
					sg = lerp(sg, 200.0, g)
					sb = lerp(sb, 120.0, g)
				}
			}

			// ── 雲 (fBM ノイズ 4+2 オクターブ) ────────────────────────
			// 雲は空の上半分のみ (uy < 0.7 付近)
			cloud_mask := smoothstep(0.8, 0.4, uy) // 地平線に近いほど雲が薄れる

			cx1 := ux * 2.5 + time * 0.006
			cy1 := uy * 2.0 + 10.0
			cn1 := fbm(cx1, cy1, 4)

			cx2 := ux * 5.0 - time * 0.012 + 73.1
			cy2 := uy * 4.0 + 31.7
			cn2 := fbm(cx2, cy2, 2)

			cloud_density := cn1 * 0.68 + cn2 * 0.32
			cloud_alpha := cloud_density - 0.40
			if cloud_alpha < 0.0 do cloud_alpha = 0.0
			cloud_alpha = cloud_alpha * 2.5
			if cloud_alpha > 1.0 do cloud_alpha = 1.0
			cloud_alpha *= cloud_mask

			// 昼の雲は白、夕暮れはオレンジ〜ピンク、夜は暗い青灰
			cloud_r := lerp(lerp(80.0, 255.0, cloud_alpha), 255.0, day_t * 0.3)
			cloud_g := lerp(lerp(85.0, 245.0, cloud_alpha), 210.0, day_t * 0.2)
			cloud_b := lerp(lerp(100.0, 255.0, cloud_alpha), 240.0, day_t * 0.15)

			// 夕焼けで雲をオレンジに
			if sunset_t > 0.01 {
				cloud_r = lerp(cloud_r, 255.0, sunset_t * cloud_alpha * 0.5)
				cloud_g = lerp(cloud_g, 160.0, sunset_t * cloud_alpha * 0.4)
				cloud_b = lerp(cloud_b, 80.0, sunset_t * cloud_alpha * 0.5)
			}

			sr = lerp(sr, cloud_r, cloud_alpha * 0.88)
			sg = lerp(sg, cloud_g, cloud_alpha * 0.88)
			sb = lerp(sb, cloud_b, cloud_alpha * 0.88)

			// ── 星 (夜のみ) ─────────────────────────────────────────────
			night_t := clamp01(1.0 - day_t * 3.0)
			if night_t > 0.0 && cloud_alpha < 0.3 {
				star_hash := _hash(i32(ux * 400.0), i32(uy * 300.0))
				if star_hash > 0.988 {
					twinkle := fast_sin(time * 3.0 + star_hash * 100.0) * 0.5 + 0.5
					star_bright := night_t * twinkle * (1.0 - cloud_alpha * 3.0)
					sr = lerp(sr, 255.0, star_bright * 0.9)
					sg = lerp(sg, 255.0, star_bright * 0.9)
					sb = lerp(sb, 255.0, star_bright)
				}
			}

			// ── 水面反射 ─────────────────────────────────────────────────
			rr, gg, bb: u8

			if is_water {
				dh := f32(y - HEIGHT / 2) / f32(HEIGHT / 2) // 0〜1 (水面奥〜手前)

				// 波の揺らぎ（高周波 shimmer）
				wx := ux * 60.0 + time * 1.8
				wy := dh * 40.0 + time * 0.5
				shimmer := fast_sin(wx) * fast_sin(wy) * 0.5 + 0.5

				// 水面ほど暗く・青く（浅い部分は空色が映る）
				darken := 0.35 + (1.0 - dh) * 0.25
				shimmer_add := shimmer * 10.0 * (1.0 - dh * 0.5)

				rr = u8(clamp01((sr * darken + shimmer_add) / 255.0) * 255.0)
				gg = u8(clamp01((sg * darken + shimmer_add) / 255.0) * 255.0)
				bb = u8(clamp01((sb * darken + shimmer_add + 5.0) / 255.0) * 255.0)
			} else {
				rr = u8(clamp01(sr / 255.0) * 255.0)
				gg = u8(clamp01(sg / 255.0) * 255.0)
				bb = u8(clamp01(sb / 255.0) * 255.0)
			}

			idx := (y * WIDTH + x) * 4
			pixel_buffer[idx + 0] = rr
			pixel_buffer[idx + 1] = gg
			pixel_buffer[idx + 2] = bb
			pixel_buffer[idx + 3] = 255
		}
	}
}

main :: proc() {
	init_noise()
}
