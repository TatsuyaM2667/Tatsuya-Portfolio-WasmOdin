import { useEffect, useRef, useState } from "react";

// Tokyo Night に馴染む CSS フォールバック用グラデーション。
// WASM のロード中/失敗時でも「真っ暗」にならないようにするための保険。
const FALLBACK_GRADIENT =
  "linear-gradient(to bottom, #16161e 0%, #1a1b26 45%, #24283b 100%)";

// 目標フレームレート。60fps ではなく 30fps に抑えることで
// CPU 負荷をおよそ半分にし、常時裏で動く背景アニメとしては十分滑らかに保つ。
const TARGET_FPS = 30;
const FRAME_BUDGET_MS = 1000 / TARGET_FPS;

// マウス移動でさざ波を発生させる間隔（ms）。短すぎると波紋が乱立して不自然になる
const RIPPLE_THROTTLE_MS = 140;

interface WasmExports {
  memory: WebAssembly.Memory;
  get_width: () => number;
  get_height: () => number;
  get_buffer_ptr: () => number;
  init_noise: () => void;
  spawn_ripple: (x: number, y: number, time: number, strength: number) => void;
  render_frame: (time: number) => void;
}

const Background = () => {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    let animationFrameId: number;
    let cancelled = false;
    let lastRenderTime = 0;
    let wasm: WasmExports | null = null;

    // ── ポインター位置とパララックス（視差）用の状態 ──────────────────
    // target: 実際のポインター位置（0〜1、画面中央が 0.5,0.5）
    // smoothed: 毎フレーム target へ緩やかに追従する値。これを使うことで
    //           カクつかず自然な「水面を覗き込むような」視差の動きになる
    const pointer = { targetX: 0.5, targetY: 0.5, smoothX: 0.5, smoothY: 0.5 };
    let lastRippleTime = 0;

    const isOverWater = (yFrac: number) => yFrac > 0.5;

    const spawnRippleAt = (
      xFrac: number,
      yFrac: number,
      nowMs: number,
      strength: number,
    ) => {
      if (!wasm || !isOverWater(yFrac)) return;
      const dh = (yFrac - 0.5) / 0.5; // 0(水平線)〜1(手前) の水面座標に変換
      wasm.spawn_ripple(xFrac, dh, nowMs / 1000.0, strength);
    };

    const handlePointerMove = (e: PointerEvent) => {
      const xFrac = e.clientX / window.innerWidth;
      const yFrac = e.clientY / window.innerHeight;
      pointer.targetX = xFrac;
      pointer.targetY = yFrac;

      const now = performance.now();
      if (now - lastRippleTime > RIPPLE_THROTTLE_MS) {
        lastRippleTime = now;
        spawnRippleAt(xFrac, yFrac, now, 1.0);
      }
    };

    const handlePointerDown = (e: PointerEvent) => {
      const xFrac = e.clientX / window.innerWidth;
      const yFrac = e.clientY / window.innerHeight;
      spawnRippleAt(xFrac, yFrac, performance.now(), 1.8);
    };

    const handlePointerLeave = () => {
      // 画面外に出たら中央に戻す（パララックスを穏やかにニュートラルへ）
      pointer.targetX = 0.5;
      pointer.targetY = 0.5;
    };

    // pointer-events:none の背景でもクリック/移動を検知できるよう window で監視する
    window.addEventListener("pointermove", handlePointerMove, {
      passive: true,
    });
    window.addEventListener("pointerdown", handlePointerDown, {
      passive: true,
    });
    window.addEventListener("pointerleave", handlePointerLeave);
    window.addEventListener("blur", handlePointerLeave);

    const initWasm = async () => {
      try {
        // build.ts で生成された main.wasm をロード
        // (Odin側はホスト関数への依存を持たない完全自己完結ビルドなので
        //  importObject は空でよい)
        const response = await fetch("/main.wasm");
        const buffer = await response.arrayBuffer();
        const module = await WebAssembly.instantiate(buffer, {});
        if (cancelled) return;

        wasm = module.instance.exports as unknown as WasmExports;

        // Odin側の定数を単一の真実の情報源として解像度を取得
        const width = wasm.get_width();
        const height = wasm.get_height();
        canvas.width = width;
        canvas.height = height;

        // ノイズテクスチャを一度だけ初期化（freestanding ターゲットは
        // main() が自動実行されないため明示的に呼ぶ必要がある）
        wasm.init_noise();

        const bufferSize = width * height * 4;

        const renderLoop = (timestamp: number) => {
          if (cancelled || !wasm) return;
          animationFrameId = requestAnimationFrame(renderLoop);

          // パララックスは毎フレーム滑らかに追従させる（レンダー間引きとは独立）
          pointer.smoothX += (pointer.targetX - pointer.smoothX) * 0.06;
          pointer.smoothY += (pointer.targetY - pointer.smoothY) * 0.06;
          const px = (pointer.smoothX - 0.5) * 2; // -1〜1
          const py = (pointer.smoothY - 0.5) * 2;
          canvas.style.transform = `scale(1.06) translate(${(-px * 12).toFixed(2)}px, ${(-py * 7).toFixed(2)}px)`;

          // 30fps にスロットルして CPU 負荷を抑える
          if (timestamp - lastRenderTime < FRAME_BUDGET_MS) return;
          lastRenderTime = timestamp;

          const timeInSeconds = timestamp / 1000.0;

          // 1. Odin側でピクセル計算を実行
          wasm.render_frame(timeInSeconds);

          // 2. Odinのメモリを直接 JS の配列として読み取る（ゼロコピー）
          const pixels = new Uint8ClampedArray(
            wasm.memory.buffer,
            wasm.get_buffer_ptr(),
            bufferSize,
          );

          // 3. Canvasに転送
          ctx.putImageData(new ImageData(pixels, width, height), 0, 0);

          if (!ready) setReady(true);
        };

        animationFrameId = requestAnimationFrame(renderLoop);
      } catch (err) {
        console.error("WASM Load Error:", err);
      }
    };

    initWasm();

    return () => {
      cancelled = true;
      cancelAnimationFrame(animationFrameId);
      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("pointerleave", handlePointerLeave);
      window.removeEventListener("blur", handlePointerLeave);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        zIndex: -10,
        pointerEvents: "none",
        overflow: "hidden",
        background: FALLBACK_GRADIENT,
      }}
    >
      <canvas
        ref={canvasRef}
        style={{
          display: "block",
          width: "100%",
          height: "100%",
          objectFit: "cover",
          opacity: ready ? 1 : 0,
          transition: "opacity 0.7s ease-in, transform 0.05s linear",
          willChange: "transform",
        }}
      />
    </div>
  );
};

export default Background;
