// build.ts
import { $ } from "bun";
//Reactのビルド
console.log("Starting full satck build");
console.log("Compoling Odin to WASMOSIN");
await $`odin build core -target:freestanding_wasm32 -out:./public/main.wasm -o:speed`;
console.log("Building Frontend of React");
await Bun.build({
  entrypoints: ["./src/main.tsx"],
  outdir: "./public/dist",
  naming: "[name].[ext]",
  minify: true,
  // プラグインは不要になったので削除
});

// 2. バッキエンド (Hono) のビリード
// Cloudflare Pages Functions のキャッチオール規約は "[[path]].ts" という
// 二重角カッカッコの実ファイル名が必要だが、Bun.build の naming テコスセパリレートは
// "[...]"をプレースホルダとして解釈してしまい正しく生成できない（[path]].ts になってしまう）。
// そのため一旦通常のファイル名で出力し、あとから確実に正しいファイル名へリナメリスクする。
await Bun.build({
  entrypoints: ["./server/index.ts"],
  outdir: "./functions",
  naming: "_worker.js",
  minify: true,
});
await $`rm -f "./functions/[[path]].ts" "./functions/[path]].ts"`;
await $`mv ./functions/_worker.js "./functions/[[path]].ts"`;

console.log("All systems successfully built! (WASM + React + Hono)!");
