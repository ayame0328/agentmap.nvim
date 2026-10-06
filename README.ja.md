# agentmap.nvim

Claude Code のエージェントたちがいま何をしているかを、Neovim の中で図にして見る道具です。

![agentmap.nvim：エージェントが動き、1 つを図から一時停止して指示つきで再開し、終わる直前に関門で待たせる。その後その子が確認のために止まり、HUMAN CHECK の箱が紫から緑に変わる様子](demo/agentmap.gif)

*動画は作り物の記録（`demo/`）を再生したものです。実際の作業の記録は映っていません。*

Claude Code は、仕事の一部を別のエージェント（子）に任せることができ、子がさらに孫に任せることもあります。
agentmap.nvim はその流れを、`START` から段を順にたどって `END` に至る図にします。
誰が誰に任せたか、どれが動いていて、どれが終わり、どこで人の判断を待っているかが一目で分かります。
図は Claude Code の作業に合わせて自動で書き換わり、記録は残るので、あとから過去の実行も開けます。

[English README](README.md)

## できること

- **図で見る。** 親・子・孫を箱にして、`START ▶ 段1 ▶ 段2 ▶ … ▶ END` の順に並べます。
  同時に動いたエージェントは同じ段に縦に並びます。箱の状態は文字と色の両方で出ます：
  `[PENDING]` 灰（まだ動き始めていない）、`[RUNNING]` 黄（動いている）、`[WAITING]` 紫（あなたの答え待ち）、
  `[REVIEW]` 青（レビュー待ち）、`[DONE]` 緑（終わった）、`[REWORK]` / `[FAILED]` 赤（やり直し・失敗）。
  図は、あなたが出した指示 1 回ごとに 1 枚です。
- **任せた理由・作業の経過・報告を読む。** エージェントの詳細画面に、親がなぜその仕事を任せたか、
  子がどう進めたか（子が書いた一言と使った道具を時刻順に）、変えたファイル、最後の報告が出ます。
- **人の確認（HUMAN CHECK）。** Claude があなたに選択肢で質問したとき（AskUserQuestion）、
  紫の `[WAITING]` の箱が図に出ます。質問のきっかけになった子の箱とつながっていて、答えると緑になります。
- **レビューと差し戻し。** エージェントの仕事に `PASS`（合格）・`RETRY`（やり直し）・`ESCALATE`（人に上げる）を、
  理由と一緒に記録できます。記録は上書きせず履歴として残り、やり直しは同じエージェントの 2 回目として表示されます。
- **書き出し。** 1 回の指示ぶんの図を Markdown・HTML・PDF に保存できます（Mermaid の図と文字の木を含む）。
  報告書やプルリクエストに貼るときに使えます。
- **箱ごとの進み具合（%）。** 手順表の「済んだ数 ÷ 全部の数」を事実として出し、手順と手順の間だけを
  過去の自分の記録から推定します。推定の数字には `~` が付きます。動いているエージェントへ入る線の上を
  光の点が親から子へ流れ、エージェントが終わると数秒だけ子から親へ戻ります（下の「進み具合と光」）。
- **動いているエージェントへの修正指示。** 動いている箱で `s` を押して直してほしいことを書くと、
  子には終わろうとした瞬間に届き（終わりを 1 回止めて続けさせます）、選べば親経由で今すぐ伝えることもできます（親が SendMessage で渡します）。
  親（メインの Claude）には端末に打ち込む形で届きます（下の「動いているエージェントへの修正指示」）。
- **一時停止。** 動いている箱で `x` を押すと、そのエージェントは次に道具を使う直前か終わる直前で止まり、
  あなたを待ちます（最長 10 分）。再開するときに指示を添えることもできます。
  関門（`X`）を入れると、子は終わる直前に毎回止まり、あなたの「通す／直す」を待ちます。止まっている箱は橙になります
  （`[PAUSED]` / `[GATE]`。下の「一時停止と関門」）。

### 似た道具との違い

Claude Code のエージェントを見張る道具はほかにもあります（例：
[claude-code-hooks-multi-agent-observability](https://github.com/disler/claude-code-hooks-multi-agent-observability)、
[agents-observe](https://github.com/simple10/agents-observe)）。これらは手元でサーバーを動かし、ブラウザの画面で見る作りです。
agentmap.nvim は **Neovim の中で**見ます。サーバーもブラウザも要りません。図はコードの隣のタブに開き、
`t` でそのエージェントの会話の記録、`d` で変更の差分が開きます。記録は手元のディスクにある普通のファイル（1 行 1 件の JSON）です。

## しくみ

```
Claude Code ── hooks ──▶ bin/agentmap-collect ──▶ <保存先>/projects/<プロジェクト>/runs/<セッション>/hooks.jsonl
 （動きは変えない）       （Python 3、標準部品だけ）                     │
                                                                          ▼
                                                  Neovim：:AgentMap がファイルを読み、変化を見張る
```

- Claude Code には「hooks」という、決まったときに外のプログラムを呼ぶ仕組みがあります。
  agentmap.nvim はこれで小さな記録係を呼び、出来事ごとに短い 1 行を書き足します。
  記録係は失敗しても Claude Code に影響を出さず、Claude Code の動きを変えることもありません。
  例外は 2 つで、あなたが書いた修正指示を届けるときは、そのエージェントの終わり（`SubagentStop` / `Stop`）を 1 回だけ止めて指示を渡します。
  また、あなたが一時停止を置いたときは、再開するまで（最長 10 分）hook の中でそのエージェントを待たせます。
- ほとんどの hooks は「待たせない」形で登録するので、Claude Code は記録を待ちません。
  `Stop`・`SubagentStop`・`SessionEnd` は待たせる形です（数ミリ秒）。待たせない形だと Claude Code の終了と同時に消えてしまったためと、
  終わり際に修正指示を届けるためです。一時停止のために、待たせる形の `PreToolUse` をもう 1 つ登録します。
  中身は「一時停止の印のファイルがあるか」を見るだけの 1 行のシェルで、止めているものが無ければ約 2 ミリ秒で抜けます。
  修正指示はここでは届けません（`steer.mode = "deny"` か `"context"` にしたときだけ届けます）。
- Neovim はその記録を読むだけです。Claude Code が動いている間に Neovim を開いている必要はなく、あとから見られます。

## 必要なもの

| | 版 |
|---|---|
| Neovim | 0.10 以上 |
| Python | 3（標準部品だけ）。`python3` → `python` → `py -3` の順に探します |
| Claude Code | 2.1.283 〜 2.1.289 で確かめました（下の「対応している版」を参照） |
| OS | Linux・macOS・WSL。Windows で直接動かす Neovim は**試験的な対応**です |

なくても動くもの：`git`（差分の画面に使う）、[oil.nvim](https://github.com/stevearc/oil.nvim)（`w` キーでエージェントの作業フォルダを開く）、
Chrome などのブラウザ（PDF の書き出しに使う）。一覧から選ぶ画面は Neovim 標準の `vim.ui.select` を使うので、
snacks.nvim・telescope・fzf-lua・mini.pick のどれかをそのために設定していれば、その見た目になります。必須のプラグインはありません。

## 入れ方

[lazy.nvim](https://github.com/folke/lazy.nvim) の場合：

```lua
{
  "ayame0328/agentmap.nvim",
  lazy = false,                   -- 起動時に読み込む（下の説明を参照）
  opts = { lang = "ja" },         -- 画面を日本語にする
  keys = {
    { "<leader>aa", "<Cmd>AgentMap<CR>",       desc = "AgentMap: 図を開く" },
    { "<leader>ar", "<Cmd>AgentMapRuns<CR>",   desc = "AgentMap: 過去の実行" },
    { "<leader>ae", "<Cmd>AgentMapExport<CR>", desc = "AgentMap: 書き出し" },
  },
}
```

`setup()` は呼ばなくても、コマンドはそのまま使えます。`lazy = false` は消さないでください。
`keys` だけだと lazy.nvim はそのキーを押すまでプラグインを読み込まず、それまで
`:AgentMapInstallHooks` も `:checkhealth agentmap` も存在しません。起動時に読み込んでも、読むのは小さなファイル 1 つで、体感できる差はありません。

そのあと 1 回だけ、次を行います。

1. `:AgentMapInstallHooks` を実行します。Claude Code の設定ファイル（`settings.json`）に何を足すかを差分で見せ、
   書き換えてよいかを聞いてきます。ほかの設定や hooks はそのまま残り、元のファイルは
   `settings.json.bak-<日時>` として控えが残ります。何度実行しても同じ結果です。
   プラグインを新しくしたあと `:checkhealth agentmap` が「古い」と言ったら、もう一度実行してください。
2. `:checkhealth agentmap` を実行します。Neovim・Python・記録係・Claude Code のフォルダ・hooks・記録の保存先・
   なくても動く道具を順に確かめて、結果を出します。
3. Claude Code を新しく起動します。そのセッションから記録されます。
4. 下の「書き方の決まり」の文を `CLAUDE.md` に貼ります（おすすめ）。

hooks を入れる前のセッションも、Claude Code が残している会話の記録から `:AgentMapRuns` または `:AgentMapImport` で取り込めます。

### 前の版から上げたとき

0.1.1 から 0.1.2 に上げたら、`:AgentMapInstallHooks` をもう一度実行してください。届ける hooks に `--pause` と 630 秒の timeout が付き、
修正指示はエージェントが終わろうとした瞬間に届くようになり（古い登録は次の道具の直前に道具のエラーとして渡すので、今のモデルは無視することがあります）、
`SendMessage` を記録します（親経由で伝えたことの確認用）。実行するまで、一時停止は断られ、子への `s` は先に `:AgentMapInstallHooks` を実行するよう案内します。
記録、親の端末への指示、親経由はそのまま動きます。

0.1.0 から上げたら、`:AgentMapInstallHooks` をもう一度実行してください。0.1.1 では、
TaskCreate / TaskUpdate / TaskList（親の手順表）を記録し、修正指示を届ける待たせる形の `PreToolUse` を足し、
`SubagentStop` を待たせる形に変えます。実行するまで `:checkhealth agentmap` は「古い」と出します。
`steer.mode` を変えたときも、hooks のコマンドに書き込まれる値なので、もう一度実行してください。

### Claude Code を使わずに試す

```sh
cd ~/.local/share/nvim/lazy/agentmap.nvim      # プラグインが入っている場所
python3 demo/replay.py --root /tmp/agentmap-demo --claude-dir /tmp/agentmap-demo-claude &
sleep 1; AGENTMAP_DIR=/tmp/agentmap-demo nvim -c AgentMap
```

上の動画と同じ作り物のセッション（約 35 秒）を、本物の記録係を通して再生します。一時停止は Claude Code と同じように再生を待たせるので、
hooks を登録してあれば `x` と `X` もこの再生で試せます。
`sleep 1` は最初の記録が書かれるのを待つためです。無いと `:AgentMap` が記録より先に動いて
「記録された run がありません」と出ることがあります（その場合は `:AgentMap` をもう一度実行すれば開きます）。

## 使い方

### コマンド

| コマンド | すること |
|---|---|
| `:AgentMap [session_id [prompt_id]]` | いちばん新しい指示の図を開く（新しい実行が始まったら追いかける） |
| `:AgentMapRuns` | 過去の実行を一覧から選んで開く |
| `:AgentMapAgent {番号\|ID}` | エージェントの詳細 |
| `:AgentMapRefresh` | 読み直す |
| `:AgentMapExport [markdown\|html\|pdf] [保存先]` | 図に出している指示を書き出す |
| `:AgentMapReview {番号\|ID} {PASS\|RETRY\|ESCALATE\|SUBMIT} [理由]` | レビューを記録する |
| `:AgentMapInstallHooks [settings.json]` | Claude Code に記録用の hooks を登録する |
| `:AgentMapImport [session_id]` | 会話の記録から実行を取り込む |
| `:AgentMapSteer {番号\|ID} [本文]` | エージェントに修正指示を送る（本文が無ければ書く窓を開く） |
| `:AgentMapPause {番号\|ID} [next\|stop]` | エージェントを一時停止する。`next`（既定）は次の道具の直前か終わる直前の早い方、`stop` は終わる直前だけ |
| `:AgentMapResume {番号\|ID}` | 止めたエージェントを再開する（関門で待っている箱なら通す） |
| `:AgentMapGate [on\|off]` | 図に出している実行の関門を入れる／切る（引数なしは反転） |

### 図の画面のキー

キーはすべて図の画面の中だけで効きます。ふだんのキーには影響しません。
どこからでも図を開くキーが欲しいときは `keymaps = { global = true }` で `<leader>aa`・`<leader>ar`・`<leader>ae` が足されます。

| キー | すること |
|---|---|
| `1`〜`9` | その番号のエージェントの詳細 |
| `Enter` | カーソルのある箱の詳細（HUMAN CHECK の箱なら質問の中身） |
| `n` / `p` | 次 / 前の箱へ移動 |
| `+` / `-` | 子を開く / 畳む |
| `z` / `BS` | このエージェントから下だけを表示 / 1 段上へ戻る |
| `t` | そのエージェントの会話の記録 |
| `d` | そのエージェントの変更の差分（git diff） |
| `w` | そのエージェントの作業フォルダへ移動 |
| `a` | レビュー（提出 / PASS / RETRY / ESCALATE / 再実行の記録 / 名前を付ける） |
| `s` | 修正指示を書く（子には終わる直前に／親経由で今すぐ。下の「動いているエージェントへの修正指示」） |
| `x` | 一時停止／再開（関門で待っている箱なら「通す／直す」のメニュー。下の「一時停止と関門」） |
| `X` | この実行の関門を入れる／切る（子は終わる直前に毎回止まり、通す／直すを待つ） |
| `e` | 書き出し |
| `r` | 読み直し |
| `R` | 過去の実行の一覧 |
| `v` | 図 ↔ 一覧（木の形）の切り替え |
| `?` | キーの一覧 |
| `q` | 閉じる |

詳細・会話の記録・差分の画面では、`BS` で 1 つ前の画面に戻り、`q` で閉じ、`Enter` でその行の
エージェント・親・HUMAN CHECK を開きます。`t` / `d` / `w` / `a` / `s` / `x` は図の画面と同じです。

図が画面の幅に入らないときは、一覧（木の形）で開きます。`v` で切り替えられます。

### 進み具合と光

箱には、経過時間の隣に進み具合が出ます。

```
[RUNNING] ~62.4% 12:34      推定：先頭に "~"
[REVIEW] 66.6% 12:34        事実だけ（3 つの手順のうち 2 つが済んだ）
[DONE] 100.0% 15:02
```

- **事実として数えるもの。** そのエージェントの手順表の「済んだ手順の数 ÷ 全部の手順の数」です。
  親（メインの Claude）は自分の手順表を TaskCreate / TaskUpdate で作り、hooks がそれを記録します。
  子はこの道具を使えない（Claude Code 2.1.288）ので、文章で `## 手順` と `手順 N 完了` を書きます（下の「書き方の決まり」）。
  詳細画面に手順の一覧が出ます。
- **推定するもの（`~`）。** いま実行中の手順の中だけです。「経過時間 ÷ 似た作業の典型的な時間」で埋めます。
  典型的な時間は、あなた自身の過去の記録の中央値です（エージェントの種類とモデルごと。手順ごとの記録がまだ無い間は、
  1 件ぶんの時間を手順の数で割ったもの）。親の実行中の手順は、動いている子の進み具合の平均で埋めます。
  数字は切り捨てで、エージェントが終わるまで 100 にはなりません。実際より進んで見えないようにするためです。
  エージェントが手順表を書き直すと、数字が下がることがあります。
- **手順表の無い箱**は、経過時間だけから推定します（経過時間 ÷ 典型的な時間、上限 95.0%）。これにも `~` が付きます。
  数字を出したくなければ `progress.no_steps = "none"` にします。
- **手順表の無い親**（手順表を作る前のメインの Claude、Workflow の箱）は、子の進み具合の単純平均を出します。
  終わった子は 100、まだ始まっていない子（`PENDING`）は 0 として数えるので、これから動く子が残っている間に数字が先走りません。
- **典型的な時間**は、終わったエージェントの記録から作ります（`:checkhealth agentmap` に件数が出ます）。
  記録が無い間は 1 件 10 分（`progress.default_ms`）とみなします。記録が増えるほど当たるようになり、
  手順ごとの時間は 0.1.1 で手順の記録が十分に溜まってから使われます。
- **毎秒の描き直し。** 動いているものがある間は、図を 1 秒ごとに描き直します（変わった行だけ）。
  典型的な時間が長いと、小数点以下は数秒に 1 回しか変わりません。図が隠れているときや別のタブにいる間は止まります。
  書き出しには、書き出した時点の値が入ります。
- **光。** 図（箱の形）では、`[RUNNING]` のエージェントへ入る線の上を、光の点が親から子の向きに流れ続けます。
  そのエージェントが終わった瞬間に、同じ線を子から親の向きに 3 秒だけ流れて止まります（`animation.back_ms`）。
  あなたの答えを待っている HUMAN CHECK へ入る線には、紫の光が流れます。動くのは色だけで、文字は書き換えません。
  光る線が無いときはタイマーも止まります。一覧（木の形）では光りません。色が 16 色より少ない端末では、光の頭を太字と反転で描きます。
- `progress = false` で箱の中の数字を消します（詳細画面と書き出しには出ます）。`animation = false` で光を完全に止めます。
- あとで推定の当たり外れを確かめるため、動いている箱ごとに 30 秒に 1 行と、終わったときに 1 行を
  `<保存先>/progress_log.jsonl` に書きます（`progress.log = false` で止まります）。誤差の中央値は `:checkhealth agentmap` に出ます。

### 画面の言葉

標準は英語です。日本語にするには `opts = { lang = "ja" }`、またはプラグインが読み込まれる前に `vim.g.agentmap_lang = "ja"` とします。

## 設定

設定できる項目と、何も指定しないときの値です。

```lua
require("agentmap").setup({
  lang = "en",                 -- 画面の言葉 "en" | "ja"。指定が無ければ vim.g.agentmap_lang を見る
  root = nil,                  -- 記録の保存先。nil → $AGENTMAP_DIR → stdpath("data") .. "/agentflow"
  claude_config_dir = nil,     -- Claude Code の設定フォルダ。nil → $CLAUDE_CONFIG_DIR → ~/.claude
  python = nil,                -- nil → "python3"・"python"・"py -3" の順に探す。文字列か表で指定もできる
  open = "tab",                -- 図を開く場所 "tab" | "vsplit" | "current"
  aux_width = 0.45,            -- 右側の詳細画面の幅（画面に対する割合）
  box_w = 26,                  -- 箱の内側の幅（文字数）
  col_gap = 7,                 -- 箱と箱の横のすき間
  mode = "auto",               -- "box"（図）| "tree"（一覧）| "auto"（入らなければ一覧）
  poll_ms = 1500,              -- ファイルの変化を見に行く間隔（ミリ秒）
  debounce_ms = 200,           -- 変化が続いたとき、まとめて描き直すまでの待ち時間
  switch_delay_ms = 15000,     -- 見ている指示が終わってから、次の指示の図へ切り替えるまでの待ち時間
  detail = { progress_max = 40, note_chars = 120, report_chars = 4000, lead_chars = 400 },
  transcript = { max_chars = 2000, max_bytes = 5e6, notes_first_bytes = 1e6, notes_max = 400 },
  review = {
    provider = "auto",         -- "auto" | "manual" | 登録した判定係の名前
    rubric = nil,              -- 自分の RUBRIC.md の場所。nil → 同梱の rubric/RUBRIC.md
  },
  keymaps = { global = false },     -- true で <leader>aa / <leader>ar / <leader>ae を足す
  hooks = { settings_path = nil },  -- nil → <claude_config_dir>/settings.json
  export = {
    html_command = nil,        -- HTML に変える別のコマンド（標準入力に Markdown、最後の引数に題名、標準出力に HTML）
    pdf_command = nil,         -- PDF にするコマンド（%{html} %{out} %{title} を置き換える）。nil → PDF は使えない
  },
  brief = { markers = nil },   -- 予約のみ（目印の言葉を変える機能は今後の予定）
  progress = {                 -- false を渡すと { enabled = false }
    enabled = true,            -- 箱に % を出す（false: 箱だけ消す。詳細画面と書き出しには出る）
    tick_ms = 1000,            -- 動いているものがある間、図を描き直す間隔（% と経過時間が動く）
    default_ms = 600000,       -- 過去の記録が無いときの、エージェント 1 件の典型的な時間（10 分）
    min_samples = 3,           -- 種類・モデルごとの中央値を使うのに要る件数
    no_steps = "time",         -- 手順表の無い箱："time" = 経過時間から推定（上限 95.0）| "none" = 出さない
    log = true,                -- 推定の答え合わせ用に <保存先>/progress_log.jsonl を書く
  },
  animation = {                -- false を渡すと { enabled = false }
    enabled = true,
    frame_ms = 100,            -- 1 コマの長さ
    period = 6,                -- 光の点と点の間隔（文字数）
    tail = 2,                  -- 光の頭の後ろの尾の長さ（文字数）
    back_ms = 3000,            -- エージェントが終わったあと、子から親へ流す時間
    max_paths = 40,            -- 同時に光らせる線の上限
  },
  steer = {                    -- false を渡すと { enabled = false }
    enabled = true,            -- false: 配達用の hooks を登録しない。s を押すと「無効」と知らせる
    mode = "stop",             -- "stop": 終わろうとした瞬間に届ける（SubagentStop / Stop で終わりを 1 回止める）
                               -- "deny" / "context": 次の道具の直前にも届ける（道具を止める／文として添える）。
                               -- 今のモデルは道具の結果として届いた文を無視することがある
    relay = "menu",            -- "menu": 親の端末があれば s に「親経由で今すぐ」を出す | "always": それを先に | "never": 出さない
    root_via = "terminal",     -- 親への届け方 "terminal" | "hook"（番の終わり）
    no_terminal = "stop",      -- Claude の端末が見つからないとき "stop"（親は番の終わり）| "clipboard" | "none"。"hook" は "stop" と同じ
    submit_delay_ms = 300,     -- 本文のあと、この ms 待って Enter を送る（0 だと 1 回で送るが、長い行は
                               -- Claude Code の入力欄に残って送信されない。下の「知っておくこと」）
    input = "window",          -- "window"（浮かせた小さな窓）| "line"（1 行の入力）
    text_max = 4000,           -- 文字数の上限
  },
  pause = {                    -- false = { enabled = false }
    enabled = true,            -- false：hooks に一時停止を付けない。x / X は「無効」と知らせる
    auto_resume_s = 600,       -- 止めたまま放置したとき、自動で再開するまでの秒数（5〜86400）
    gate = false,              -- 新しく見始める実行の関門の初期値（X で実行ごとに反転）
    release_on_exit = false,   -- true：Neovim を閉じるとき、図に出している実行の一時停止を全部解く
    notify = true,             -- 止まった・関門で待っている・自動で再開した、の知らせ
  },
})
```

`steer.mode` は hooks のコマンドに書き込まれます。変えたら `:AgentMapInstallHooks` をもう一度実行してください
（登録と設定が違うと `:checkhealth agentmap` が知らせ、それまで `s` は hooks の経路を断ります）。
`steer.at_stop` は 0.1.2 から無視します（終わり際の配達は常に有効）。
`pause.auto_resume_s` も hooks のコマンドと timeout に書き込まれます。変えたら `:AgentMapInstallHooks` を実行してください。

保存先のフォルダ名が `agentmap` ではなく `agentflow` なのはわざとです。公開前の版の記録をそのまま読めるようにしています。
環境変数も、`$AGENTMAP_DIR` の古い名前 `$AGENTFLOW_DIR` をまだ読みます。

## 書き方の決まり

agentmap.nvim は、エージェントを**なぜ**任せたか、**何を報告したか**を、Claude が決まった形で書いたときだけ画面に出します。
推測はしません。この形で書かれていない項目は「（書かれていません）」と表示されます。
次の文を `CLAUDE.md` に貼ってください（英語版は [README.md](README.md#writing-convention)）。

```markdown
## Agent に任せる・報告する・人に確認するときの書き方（agentmap.nvim が読む決まり）

agentmap.nvim は次の見出しと項目名を機械的に読んで Neovim の画面に出す。
書かれていない項目は「（書かれていません）」と表示され、推測で補われない。

**親（Agent を起動する側）：指示文の先頭 3 行**。この順・この文字（全角の【】）で始め、その後に本文を書く。

【目的】何のためにやるか（1 行）
【任せる理由】なぜ自分でやらず任せるか（1 行）
【期待する結果】何が返ってくれば完了か（1 行）

**子（起動された側）：最後の報告**。SubagentHandback で返す場合も、その message の中にこの形で書く。

## 報告
- やったこと: 何をしたか
- 方向: どういう方針で進めたか
- 理由: なぜその方針にしたか
- 残った課題: 無ければ「なし」

作業中に利用者から修正指示を受けたときは、「方向」か「理由」に、受けた指示とそれで変えたことを書く。

**子：人の確認が要るとき**。子は利用者に直接は聞けない。作業を止め、報告の代わりにこれを書いて終わる。

## 要確認
- 今の作業: 何をしていたか
- 止まっている所: どこで先に進めないか
- 確認したいこと: 聞きたいことを 1 文で
- 選択肢:
  1. 名前 → 選んだ後の進め方
  2. 名前 → 選んだ後の進め方

**親：子の要確認を受けて AskUserQuestion するとき**

- question は「<子に付けた description> について：<確認したいこと>」の形にする
- header は description の先頭（12 文字まで）
- 各 option の label は子の選択肢の名前をそのまま。description の末尾に「→ 選んだら: <進め方>」を入れる
- 自分の判断で直接聞くときも同じ形（「〜について：」の部分は不要）
- 答えが出たら、その答えに沿って続ける。子を起動し直すときは【目的】に「<答え> を選んだため」と書く

**子：手順表（進み具合として読まれる）**。作業を始める前の最初の返答に `## 手順` と番号付きの手順
（3〜8 個）を書き、1 つ終えるたびに `手順 N 完了` の行を書く。親（メインループ）は自分の手順表を
TaskCreate / TaskUpdate で作る（Claude Code 2.1.288 では子はこの道具を使えない）。agentmap.nvim は
済んだ手順の数を事実として数え、手順と手順の間は推定（`~`）として出す。
```

読み取りの細かい規則は [docs/writing-convention.ja.md](docs/writing-convention.ja.md) にあります。
日本語の目印と英語の目印（`[Goal]`、`## Report` など）は、いつでも両方読めます。混ぜても構いません。

## 人の確認（HUMAN CHECK）

Claude が AskUserQuestion であなたに質問すると、HUMAN CHECK の箱が出ます。
質問文に子の名前（description）が入っていれば、その子の箱とつながります（上の決まりはそこに名前を書く形です）。
入っていなければ、質問した側の箱につながります。あなたがターミナルで答えるまでは紫の `[WAITING]`、
答えると緑の `[DONE]` と答えが出ます。答えないまま終わったときは灰色の `[UNANSWERED]` です。
箱の上で `Enter` を押すと、質問、選択肢ごとの「選んだらどう進むか」、子の「要確認」の中身が出ます。

## 動いているエージェントへの修正指示

箱の上で `s` を押すか、`:AgentMapSteer {番号|ID} [relay] [本文]` を実行して、エージェントに直してほしいことを書きます。
小さな窓が開くので、書いたら `<C-s>`・`:w`・ノーマルモードの `Enter` のどれかで送ります。`q` で取り消します。
届け方は箱によって変わります。

| 箱 | 届け方 | いつ届くか |
|---|---|---|
| 動いている子・孫・レビュー係 | **終わり際に届ける。** 指示はその実行のフォルダに置かれます。そのエージェントが終わろうとした瞬間に、`SubagentStop` の hook が終わりを 1 回だけ止めて指示を渡します。エージェントは指示を反映して作業を続け、改めて終わります。 | 終わろうとした瞬間 |
| 同上で、親（メインの Claude）の直接の子、かつこの Neovim に親の端末がある | メニューの 2 番目 **「書いて親経由で今すぐ伝える」**。親の端末に `[AgentMap] サブエージェント [3]「<名前>」（agent id <id>）に SendMessage で次を伝えてください：<本文>` と打ち込み（英語の画面なら英語の文）、親が `SendMessage` で子へ渡します。 | 今（親の次の切れ目 → 子の次の道具の切れ目） |
| 道具の直前で一時停止中の子（`[PAUSED]`） | 止まれを解いて作業を続けさせ、上と同じく終わり際に届けます。 | 終わろうとした瞬間 |
| 終わる直前で止まっている子（`[GATE]`、または終わり際で止めた子） | 待っている hook がその場で渡します。 | 今 |
| 親（ROOT、メインの Claude） | **端末に打ち込む。** この Neovim の中の `:terminal` で動いている `claude` に、`[AgentMap] <本文>` と Enter を送ります。Claude Code は作業中に打たれた文字を次の切れ目で読みます。止まっていれば新しい指示として始まります。道具の直前で一時停止中なら、先に止まれを解きます。 | 次の切れ目 |
| 親で、この Neovim に Claude の端末が無い | 親の `Stop` の hook が番の終わりを 1 回だけ止めて指示を渡します（`steer.no_terminal = "stop"`）。 | 番の終わり |
| 終わった箱（`DONE` / `REWORK` / `FAILED`） | **親の端末へ、やり直しの依頼を送る。** 文面は `[AgentMap] エージェント [3]「<名前>」（id …、10:31 終了）をやり直してください：<本文>。同じ任せ方で、何が変わったかを報告してください。` です（英語の画面なら英語）。差し戻し（REWORK）は自動では記録しません。やり直すかは親が決めます。 | — |

子に終わり際で指示が届くと、その親にも 1 回だけ知らせが届きます。届け方は、その親への普通の指示と同じです
（親がメインの Claude なら端末、無ければ番の終わり。親が子エージェントならその終わり際）。文面は
`[AgentMap] The user sent this instruction directly to your sub-agent [2] "<名前>": <本文>. If it also affects other sub-agents or your plan, update them.`
のような形です（モデル向けの文なので、画面の言葉によらず英語です）。親がもう終わっていれば送りません。
親経由で伝えた指示は、親自身が渡したので知らせません。子には、報告の中で受けた指示に触れるよう頼みます。

知っておくこと：

- **エージェントからの見え方。** 終わり際では、Claude Code が指示を `Stop hook feedback:` に続けて
  `[AgentMap] Instruction from the user, typed in Neovim (AgentMap) while you were working. It reaches you now, just before you finish: <本文> Apply it now, continue your task, then finish again.`
  という形で会話に入れます（子には、最後の報告で触れるよう頼む一文も付きます）。道具の結果ではなく、利用者側の行として入ります。
  Claude Code 2.1.291 で試したところ、Haiku と Sonnet の子は 17 回中 17 回、親は 9 回中 9 回従いました。
- **すぐには届かず、終わる直前に届きます。** それまでの間、エージェントは古い方針のまま作業を進めます。
  試験では、あと 6 回道具を使う子に、書いてから 14〜17 秒後に届きました。これはその子の残りの作業時間そのものです。
  長い作業なら長く待つことになり、agentmap.nvim はこれを縮められません。過去の記録から残り時間を推定できるときは、知らせにその目安を添えます。
  それでは遅いときは、親経由で伝えるか、先に一時停止（`x`）してください。
- **親経由**はすぐ届きますが、従う確かさは下がります。親（Sonnet 5 回中 5 回、Haiku 2 回中 2 回）は打ち込んでから 5〜8 秒で
  本文を変えずに `SendMessage` を使い、Claude Code は `Message queued for delivery to <id> at its next tool round.` と出しました。
  子には次に道具を使う切れ目で、親からの伝言として届きます。従ったのは Sonnet 1 回中 1 回、Haiku 5 回中 3 回で、終わり際より弱い結果でした。
  親が子の戻りを待っている（`run_in_background: false` で起動した）子には、子が終わってから伝わります（親は子が戻ったときに打たれた文を読むため）。
  終わった子に `SendMessage` が届くと、子は同じ id のまま作業を再開します。Claude Code 2.1.291 は既定で子を背景で動かします。
  親経由は、親の直接の子（孫は対象外）で、実行が続いている間だけ選べます。
- **何をもって届いたとするか。** 終わり際は hook の記録です。親経由は、打ち込んだら「送信」、Claude Code が受け取ったら「受け取った」、
  親がその子へ `SendMessage` した記録が来たら「渡した」です（親が本文を言い換えていれば、詳細画面に実際に渡した文も出ます）。
  子が伝言を読んだかは子自身の会話の記録にしか残らないので、図では「届いた」とは言いません。
  親が渡さずに番を終えたときは知らせが出て、箱に ` ✎!` が出ます。
- **`steer.mode = "deny"` / `"context"`**（任意の設定）は、次の道具の直前にも届けます。`deny` はその道具を止めて本文を理由として返し
  （`PreToolUse:Write hook error: [AgentMap] Steering instruction from the user, …`）、`context` は道具を動かしたまま本文を添えます。
  **今のモデルはこれを無視することがあります。** 本文が利用者の言葉ではなく道具の結果の中に入るためで、2.1.291 の Sonnet の子は
  「That text came back in a tool result, not from you, so I did not follow it」と明言して従いませんでした。既定にしていないのはこのためです。
- 終わり際に止めると、Claude Code の端末に stop hook の行が出ます。止めるのが 8 回続くと Claude Code が終わらせる
  （`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`）ので、止まり続けることはありません。同じエージェントに続けて 9 件目を送ると、それは止めずに終わります。
- Claude の端末が見つからないとき（別の端末の窓で Claude Code を動かしているときなど）は、親への指示を番の終わりに届けます
  （`steer.no_terminal = "stop"`）。クリップボードにコピーする（`"clipboard"`）、送らない（`"none"`）も選べます。親経由は選べません。
  その実行のフォルダ（かその親）で動いている Claude の端末を使います。複数あって決まらないときや、別のフォルダの端末しか無いときは、1 回だけ選んでもらいます。
  送ったあとは端末を一度見てください。Claude Code が別の質問（フォルダを信頼するかの確認など）で止まっていても、agentmap.nvim には分かりません。
- 端末へは本文を 1 行で打ち込み（改行などの制御文字は空白にします。Claude Code は `\` のすぐ後の Enter を「改行」として扱い送信しないので、
  末尾の `\` の後ろには空白を 1 つ足します）、`steer.submit_delay_ms`（300 ms）あとに Enter を送ります。`0` にすると 1 回で送りますが、
  長い行（親への知らせの長さ、約 250 文字）は Claude Code 2.1.289 が貼り付けとして扱い、入力欄に残ったまま送信されません
  （短い行はどちらでも送信されます）。詳細画面では、Claude Code が読むまでは「端末へ送信」、読んだら「配達（Claude Code が受け取った）」
  と出るので、届いたかどうかが分かります。
- 送らずに知らせだけ出す場合が 2 つあります。hooks の登録が古いか、登録の `steer.mode` が設定と違うとき（`:checkhealth agentmap` が知らせます。
  0.1.1 の登録は次の道具の直前に道具のエラーとして渡すので、今のモデルは無視することがあり、終わり際には何も残りません。
  そのため子に `s` を押すと、先に `:AgentMapInstallHooks` を実行するよう案内します。親の端末・親経由の経路は関係ありません）と、
  実行が終わっているとき（セッションが閉じた run で親や終わった箱に `s` を押すと、同じフォルダの別の会話の Claude に打ち込むことになるので、
  「この実行は終わっています。新しい指示は Claude の画面で出してください」と出ます）。
- 箱の 4 行目に、届く前の指示があれば ` ✎1`（紫。親経由なら親が渡すまで）、届けてから 1 分の間は ` ✎`（緑）、
  届く前にエージェントが終わってしまったか、親が渡さなかったら ` ✎!`（赤）が出ます（そのときは知らせも出ます）。
  詳細画面に指示の一覧と全文が出ます（行の上で `Enter` を押すと全文を開きます）。まだ届いていない指示は
  `s` →「未配達を取り消す」で取り下げられます（親経由は打ち込んだ後は取り下げられません）。書き出しには「修正指示」の節が入ります。
- 置き場所：届く前の指示は `<保存先>/projects/<プロジェクト>/runs/<セッション>/steer/<エージェント>-<時刻>.json`
  （自分だけが読み書きできる 0600）、`<保存先>/steer.pending` は `steer.mode = "deny"` と `:checkhealth` のために残している印です。
  届けたものは `*.delivered.json` に名前が変わります。親経由はファイルを作らず、端末に打ち込んだ文を `events.jsonl` に残します。
  同じユーザーで動くプログラム（エージェントの Bash を含む）はこのファイルを書けるので、覚えのない指示が届いていないか、詳細画面の全文で確かめられます。

## 一時停止と関門

動いている箱で `x` を押す（または `:AgentMapPause {番号|ID}`）と、そのエージェントを一時停止します。
仕事は取り消しません。次に道具を使う直前か、終わろうとした直前の、早い方で止まって待ちます。
もう一度 `x` を押すと再開します。`:AgentMapPause {番号|ID} stop` なら終わる直前だけで止めます。
親（ROOT）も止められます。

しくみ：待たせる形の hooks（`PreToolUse`・`SubagentStop`・`Stop`）が、一時停止のファイルを探します。
見つけたら、hook は戻らずに **Claude Code の中で待ちます**（100 ミリ秒ごとにファイルを見ます）。
`x` でファイルを消すと hook が戻ります。

- **止まるもの・止まらないもの。** 止まるのはそのエージェントだけです。ほかの子は進みます。止めた子の結果を待つ親は、
  時間のかかる道具を待つのと同じように待ちます。止めた子については Claude Code の画面に何も出ません。
  親を止めたときは、Claude Code の待ち表示に `running PreToolUse hooks…` と出ます。
  止まっていることが分かるのは図です。箱が橙の `[PAUSED]`（関門なら `[GATE]`）になり、線の光が止まります。
  止まる場所にまだ来ていない間は、箱に ` ⏸` が出ます（この文字を 2 桁で描く端末では `||`）。
- **エージェントからの見え方。** 指示なしで再開したときは、何も見えません。止めていた道具はそのまま動き
  （終わりなら終わり）、道具が遅かっただけに見えます。道具の直前で止まっている箱で `s` を押すと、その場で再開して作業を続けさせ、
  指示は終わろうとした瞬間に届きます（それまでは古い方針で進みます。`x` でまた止められます）。親の場合は、止まれを解いてから端末に打ち込みます。
  関門の「直す」（または終わり際で止まっている箱で `s`）は、hook がもう終わり際で待っているのでその場で届き、
  修正指示と同じ文に `(You were paused by the user for 2 min 31 s before this instruction.)` の 1 行が足されます。
- **最長 10 分。** 止めたまま放置すると、`pause.auto_resume_s`（600 秒）で自動的に再開します。
  期限は hook 自身が壁の時計で守るので、Neovim を閉じても、PC が眠っても効きます。再開したら知らせが出ます。
- **hook の timeout が 630 秒の理由。** Claude Code は hook を `timeout` の秒数で打ち切り（指定が無ければ 600 秒。2.1.289 で確認）、
  そのあと道具を黙って動かします。timeout より長く止めると、止まっているように見えて実は動いている、という一番悪い形になります。
  そのため `:AgentMapInstallHooks` は届ける hooks を `auto_resume_s + 30` 秒で登録します。記録用の hooks は 10 秒のままです。
- **関門。** `X`（または `:AgentMapGate on`）で、図に出している実行の関門を入れます（`pause.gate` は新しく見始める実行の初期値）。
  入っている間、動いている子（孫・Workflow の中のエージェントも。親は対象外）は、終わろうとした直前で毎回止まります。
  報告はもう記録されているので、`[GATE]` の箱で `Enter` を押せば読めます。その箱で `x` を押すと、
  **通す**（終わらせる。親に報告が渡る）、**直す**（指示を書く。子は続けて働き、関門が入っていれば次の終わりでまた止まる。
  Claude Code は連続 8 回まで止められるので、直せるのは 8 回まで）、**待たせたまま報告を見る**、から選べます。
  放置すると 10 分で自動的に通ります。もう一度 `X` で関門を切ると、待っている子は全部通ります。
  関門の入／切は実行のフォルダに残るので、図を開き直しても続きます。
- **Claude Code での Esc** は親の番を止めるだけです。子（と子を待たせている hook）は動き続けます。
  親に置いた一時停止は残るので、親は次に道具を使うときにまた止まります（同じ 10 分の期限の中で）。
- **Neovim を閉じたとき**は、既定では何もしません。止めたエージェントは期限で自動的に再開し、
  図を開き直せば早めに再開させることもできます。`pause.release_on_exit = true` にすると、閉じるときに図に出している実行の
  一時停止を全部解きます。Claude Code 自体が終わると、待っている hook も終わり、一時停止は「終わった」と記録されます。
  セッションが終わるときは、記録係がその実行の一時停止のファイルを片付けます（ほかに一時停止が無ければ印も消します）。
  止まらないまま置かれた一時停止が、セッションの後まで残ることはありません。
- **hooks。** 一時停止には 0.1.2 で登録した hooks が要ります。上げたら `:AgentMapInstallHooks` を実行してください。
  古い登録のままだと `x` と `X`、子への `s` はそう知らせて何もしません。記録と端末の経路はそのまま動きます。
- **負担。** 止めているものが無ければ、道具 1 回あたりの負担は今までどおりシェルの確認 1〜2 ミリ秒です。
  一時停止のファイルが 1 つでもある間（関門が入っている間はずっと）は、道具を使うたびに記録係が起動します（約 15〜20 ミリ秒）。
  最後の一時停止が期限で再開したときは hook が印も消すので、Neovim を閉じていても、ほかのセッションが遅いまま残ることはありません。
  待っている hook は 100 ミリ秒ごとにファイルを 1 つ見るだけです（CPU 1% 未満）。
- **置き場所。** `<保存先>/projects/<プロジェクト>/runs/<セッション>/pause/<エージェント>.json` が一時停止（0600、本文なし）、
  `<エージェント>.hit.json` は止まったときに hook が書くもの（時刻・期限・道具の名前）、`GATE` は関門が入っている印、
  `<保存先>/pause.pending` は hooks のシェルが見る印です。修正指示のファイルと同じく、同じユーザーで動くプログラムなら書けます。

## レビューと判定係

エージェントの上で `a` を押すか `:AgentMapReview` で、`PASS`・`RETRY`・`ESCALATE` を理由と一緒に記録します。
最終的に決めるのはいつもあなたです。レビューはその実行の記録と `<保存先>/review_log.jsonl` に、
使った判定基準の版と一緒に残ります。同梱の判定基準 [rubric/RUBRIC.md](rubric/RUBRIC.md) は 5 つの問いでできています。
自分の基準を使うときは `review.rubric` にその場所を書きます。

「判定係」を登録すると、あなたが選ぶ前に判定を**提案**させることができます。

```lua
require("agentmap.review").register("my-judge", {
  -- 任意：この PC で使えるかどうかを答える（使えないときは理由も）
  available = function() return vim.fn.executable("my-judge") == 1, "my-judge が見つかりません" end,
  -- ctx = { agent, agent_id, state, run, rubric }。cb({ verdict = "PASS", reason = "…" }) か cb(nil) を呼ぶ
  evaluate = function(ctx, cb) cb({ verdict = "PASS", reason = "試験が通っている" }) end,
})
```

`review.provider = "auto"` なら、登録された判定係のうちこの PC で使える最初のものを使い、無ければあなたが手で選びます。
提案があっても最後に選ぶのはあなたで、提案と選んだ答えが並べて記録されます。

## 書き出し

`:AgentMapExport`（図の画面では `e`）で、図に出している指示 1 回ぶんを書き出します。
中身は、全体の概要、Mermaid の図と文字の木、各エージェントの任せた理由と報告、人の確認、レビュー、変えたファイル、使った道具です。
保存先を指定しなければ `<保存先>/projects/<プロジェクト>/runs/<セッション>/exports/` に置かれます。

- **Markdown**：いつでも使えます。
- **HTML**：CSS を中に含んだ 1 つのファイル（明るい配色・暗い配色の両方に対応）。同梱の小さな変換係で作るので、ほかの道具は要りません。
  pandoc などを使いたいときは `export.html_command` に書きます。
- **PDF**：HTML を PDF にするコマンドを `export.pdf_command` に書くと使えます。例：

```lua
-- Linux
export = { pdf_command = { "google-chrome", "--headless=new", "--disable-gpu",
  "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- macOS
export = { pdf_command = { "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "--headless=new", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- Windows（Edge）
export = { pdf_command = { "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "--headless=new", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- WSL から Windows の Chrome を使う（ファイルの場所は自動で Windows の形に直します）
export = { pdf_command = { "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe",
  "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
```

## 何を保存し、何を保存しないか

記録は手元のディスクの `<保存先>`（標準は `stdpath("data")/agentflow`）にだけ置かれ、どこにも送られません。

保存するもの（出来事ごと）：

- セッション・指示・エージェントの ID と種類、作業フォルダ、出来事の名前、時刻
- あなたの指示と、各エージェントへの指示の先頭 200 文字。決まりの 3 行（`【目的】` `【任せる理由】` `【期待する結果】`、各 300 文字まで）
- エージェントの名前（description）・種類・モデル
- 道具の名前と対象：Write / Edit ならファイルの場所、Bash ならコマンドの 1 行目（120 文字まで）
- AskUserQuestion の質問・選択肢・答え（長いものは切る）
- 子の最後の報告（2000 文字まで）と、最後の発言の先頭 200 文字
- 手順表：TaskCreate の件名と `## 手順` の各項目（各 60 文字まで）と、その状態の変化。TaskCreate の説明文（description）は保存しない
- **修正指示の本文はあなたが書いたまま**（伏せ字にしない。4000 文字まで）。`events.jsonl` と `steer/*.delivered.json` に残る。
  親経由では、親の端末に打ち込んだ文全体も `events.jsonl` に残り、エージェントが送る `SendMessage` の先頭 120 文字が `hooks.jsonl` に残る
- `progress_log.jsonl`（推定の値と実際にかかった時間。文章は入らない）と `stats.json`（かかった時間の中央値）
- 一時停止：置いた時刻、どこで止まったか、いつ再開したか（`events.jsonl`・`hooks.jsonl`）。一時停止のファイルに文章は入りません。
  止まっている間だけ、`pause/<エージェント>.hit.json` に道具の名前と `tool_use_id` が入ります

保存しないもの：

- 指示の全文、道具の実行結果、ファイルの中身、Read / Grep / Web の道具の呼び出し
- 鍵やパスワードらしい文字列：`api_key=…`、`token: …`、`password=…`、`Bearer …`、`sk-…`、`ghp_…`、
  `github_pat_…`、`AKIA…`、`xox…-`、`AIza…` は、書き込む前に `***` に置き換えます（伏せ字）

詳細画面と会話の記録の画面は、開いたときに Claude Code 自身の会話の記録（`claude_config_dir` の中）を読みます。写しは作りません。
書き出しのファイルは、あなたが書き出したときにだけ作られます。
記録を消したいときは、`<保存先>/projects/` の下のフォルダを消してください。

## コンテナ・WSL・Windows

- **Claude Code をコンテナ（devcontainer・Docker・サンドボックス）の中で動かし、Neovim は外で使う場合**：
  [docs/containers.md](docs/containers.md)（英語）を見てください。両方から見える共有フォルダが 1 つ要ります。
- **WSL**：Neovim と Claude Code を両方 WSL の中で動かすなら、Linux と同じように使えます。
- **Windows で直接動かす Neovim**：v0.1.0 では**試験的な対応**です。hooks のコマンドは bash 向けの形で書きます
  （Windows の Claude Code は Git Bash で hooks を動かします）。うまく動かないところがあれば知らせてください。

## 対応している版

Claude Code が hooks に渡す中身には版の番号が入っていません。そのため、実際の hooks の中身を採取して確かめています（`tests/fixtures/`）。

| Claude Code | 確かめた日 | 備考 |
|---|---|---|
| 2.1.283 〜 2.1.286 | 2026-10-01 | `tests/fixtures/` の実物の hooks の中身は 2.1.283 から採取 |
| 2.1.288 | 2026-10-04 | TaskCreate / TaskUpdate / TaskList の中身。修正指示（止めたときの文言、`stop_hook_active`、動いている `claude` への打ち込み） |
| 2.1.289 | 2026-10-04 | Neovim からの通しの確認（進み具合・光・修正指示・親への知らせ・HUMAN CHECK・書き出し）。`claude` に打ち込む長い行は Enter を分けて送る必要がある（`steer.submit_delay_ms`、既定を 300 に） |
| 2.1.291 | 2026-10-06 | Stop / SubagentStop の `decision: block` で渡した文に従う（子 17/17、親 9/9）。`PreToolUse` の deny に入れた文は Sonnet が無視。Agent の道具は既定で背景。`SendMessage` での親経由（子の次の道具の切れ目に届く）。終わった子に送ると再開する。対話モードでは開始の記録の無い内部の Agent の `SubagentStop` が届く（無視する） |
| 2.1.289 | 2026-10-05 | 一時停止：`timeout` を書かない hook は 600 秒で打ち切られる。書いた `timeout` は守られる（630 秒・7200 秒で確認）。timeout を超えると Claude Code は hook を終わらせ（SIGTERM）、何も表示せずに道具を動かす。Esc は裏で動いている子を止めない。裏の仕事があるときの `/exit` は 3 択（止めて終わる／裏に回して終わる／とどまる）を聞く。親の道具で hook が待つと待ち表示に `running PreToolUse hooks…` が出る。子のときは何も出ない |

使う hooks：`SessionStart`、`UserPromptSubmit`、`PreToolUse`（Agent・AskUserQuestion。一時停止用に全部の道具・待たせる形でもう 1 つ）、
`PostToolUse`（Agent・AskUserQuestion・Write・Edit・MultiEdit・NotebookEdit・Bash・EnterWorktree・ExitWorktree・TaskCreate・TaskUpdate・TaskList・SendMessage）、
`PostToolUseFailure`（Agent・AskUserQuestion）、`SubagentStart`、`SubagentStop`、`Stop`、`SessionEnd`。
知らない種類の出来事は無視するので、Claude Code に hooks の種類が増えても壊れません。
許可の判断を返せる `PermissionRequest` は使わないので、agentmap.nvim が何かを許可することはありません。
エージェントの終わりを 1 回止めるのは、あなたが書いた修正指示を届けるときだけです（`steer.enabled = false` で外せます）。
道具の呼び出しを止めるのは `steer.mode = "deny"` のときだけです。
道具の呼び出しやエージェントの終わりを待たせるのは、あなたが一時停止を置いている間だけです（`pause.enabled = false` で外せます）。

2.1.288 での注意：子は TaskCreate を使えないので、`## 手順` の書き方で手順表を作ります。止めた道具の呼び出しは、
モデルには `PreToolUse:<道具> hook error: <理由>` と見えます。hooks で届けた指示に親が従うかは、モデルによって違います
（2.1.291 では、番の終わりに届けた指示に親が 9 回中 9 回従いました）。

記録の形式には版の番号（`_v`）があり、古い版で書いた記録も読めます。

## いまの状態と今後

v0.1.0 は、作者が自分の仕事のために作った道具を公開した最初の版です。v0.1.1 で進み具合・光・修正指示を、v0.1.2 で一時停止と関門を足し、修正指示を終わり際（または親経由で今すぐ）に届けるように変えました（今のモデルは道具のエラーとして渡した文を無視することがあるため）。
Issue への返事は週に数回で、約束はできません。

予定していること：

- **Codex** への対応（仕組みは用意してあり、いまは Claude Code だけ）
- 書き方の決まりの**目印の言葉を自分で決める**設定（`brief.markers`。いまは予約だけ）
- 古い記録の自動の片付け
- Windows で直接動かす Neovim：不具合を直して、試験的な対応を外す
- 手順ごとの典型的な時間は、記録が溜まるほど当たるようになる（0.1.1 から記録を始める）

不具合の報告には、`:checkhealth agentmap` の結果と `hooks.jsonl` の数行があると助かります（個人の情報が入っていないか先に確かめてください）。
[CONTRIBUTING.md](CONTRIBUTING.md)（英語）も見てください。

## ライセンス

[MIT](LICENSE)
