import { useEffect, useRef, useState } from "react";

// Tokyo Night に馴染む CSS フォールバック用グラデーション。
// WASM のロード中/失敗時でも「真っ暗」にならないようにするための保険。
const FALLBACK_GRADIENT =
  "linear-gradient(to bottom, #16161e 0%, #1a1b26 45%, #24283b 100%)";

// 目標フレームレート。60fps ではなく 30fps に抑えることで
// CPU 負荷をおよそ半分にし、常時裏で動く背景アニメとしては十分滑らかに保つ。
const TARGET_FPS = 30;
const FRAME_BUDGET_MS = 1000 / TARGET_FPS;

interface WasmExports {
  memory: WebAssembly.Memory;
  get_width: () => number;
  get_height: () => number;
  get_buffer_ptr: () => number;
  init_noise: () => void;
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

    const initWasm = async () => {
      try {
        // build.ts で生成された main.wasm をロード
        // (Odin側はホスト関数への依存を持たない完全自己完結ビルドなので
        //  importObject は空でよい)
        const response = await fetch("/main.wasm");
        const buffer = await response.arrayBuffer();
        const module = await WebAssembly.instantiate(buffer, {});
        if (cancelled) return;

        const wasm = module.instance.exports as unknown as WasmExports;

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
          if (cancelled) return;
          animationFrameId = requestAnimationFrame(renderLoop);

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
        className="w-full h-full object-cover transition-opacity duration-700"
        style={{ opacity: ready ? 1 : 0 }}
      />
    </div>
  );
};

export default Background;
