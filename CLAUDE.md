# GW230529 Einstein Toolkit — AWS Infrastructure (Terraform)

## プロジェクト概要

[gw230529-einstein-toolkit](../gw230529-einstein-toolkit) の **Phase 4–6
(クラウド実行)** を担う sibling repo。EC2 spot ノード 1 台、S3 (成果物の正本)、
ECR (ET イメージ配布)、およびコストガードレールを Terraform で管理する。

設計の全体像と根拠は [docs/architecture.md](docs/architecture.md) にある。
本ファイルは運用ルールのみを記す。

### 確定済みの設計判断

| 論点 | 決定 | 理由 |
| --- | --- | --- |
| repo 名 | `gw230529-einstein-toolkit-aws-tf` | 本体 repo の sibling |
| 公開範囲 | public。アカウント固有値は gitignore + `.example` | Q7 |
| リージョン | 起動ごとの選択はしない。**1 回決めて固定** | ECR/S3 がリージョン束縛。移動 = 5–8 GB 再 push |
| リージョン | **us-west-2 に確定 (2026-08-19 実測)** | 下記「リージョン選定の実測結果」 |
| AZ | **us-west-2d (`usw2-az4`)**、次点 `us-west-2a` → `us-west-2c` | placement score 9 かつ c7a.48xlarge が最安 |
| インスタンス | **m7a.48xlarge が既定**。Phase 5 の実測次第で c7a.48xlarge | 参照 run のメモリ実測 438.5 GB に対し c7a の 384 GiB は余裕が無い。下記「インスタンス選定の再評価」 |
| state backend | S3 + native lockfile (`use_lockfile`) | DynamoDB テーブルが不要になる |
| S3 構成 | 1 バケット + prefix 別 lifecycle | バケット分割は分離を買わずポリシー面だけ増える |
| ネットワーク | public subnet + IGW + S3 Gateway Endpoint | private + NAT は月 33 USD、予算の 11% |
| スタック分割 | bootstrap / foundation / compute の 3 つ | **環境別ではなく寿命別**。compute の destroy がデータに届かない |
| spot instance | `aws_instance` + one-time spot、`run_enabled` フラグ | 中断後の再開が `terraform apply` 1 発になる |

### リージョン選定の実測結果 (2026-08-19、`make region-scout`)

target 192 vCPU / single-AZ / c7a・m7a・c7i の 48xlarge で計測 (当時の候補リスト。
2026-08-20 に m7a・c7a・r7a へ入れ替えた。下記「インスタンス選定の再評価」)。

| リージョン | score 9 の AZ 数 | c7a.48xlarge 最安 | spot vCPU クォータ |
| --- | --- | --- | --- |
| us-west-2 | 4 中 3 | 2.970 USD/h (us-west-2d) | 256 |
| us-east-1 | 6 中 4 | 2.996 USD/h (us-east-1a) | 256 |
| us-east-2 | 3 中 2 (1 つは 6) | 2.572 USD/h | **5** |

- **us-east-2 は脱落**。約 15% 安いがクォータが 5。緩和申請の承認待ち
  (数時間〜数日) に見合う差ではない (76 時間 run で約 30 USD)
- **us-west-2 を採用**。容量では差がつかない (どちらも score 9、クォータ済み)。
  決め手は**フォールバック AZ の価格が近い**こと:
  us-west-2 は 2.97 → 3.05 → 3.32、us-east-1 は 2.996 → 3.49 → 3.52。
  第一希望の AZ を外されたときの傷が浅い。加えて us-east-1 は
  AWS 全体の大規模障害が集中する
- **クォータ緩和申請は不要だった** — us-east-1 / us-west-2 は既に 256 vCPU。
  当初の「今すぐ申請」という申し送りは解消

**AZ は名前順ではなく明示リストで指定する (2026-08-20 修正)**

`modules/network` は当初 `slice(names, 0, az_count)` で AZ を選んでいたが、
us-west-2 の名前順は a → b → c → d なので `az_count = 3` だと
**最安・score 9 の us-west-2d が漏れ、unscored の us-west-2b が入る**。
compute は subnet を AZ 名で引くので、`availability_zone = "us-west-2d"` が
plan 時にキー不在で落ちる状態だった。

`availability_zones = ["us-west-2d", "us-west-2a", "us-west-2c"]` を
foundation の変数として渡す方式に変更。`az_count` は null 時のフォールバック
として残す。併せて `public_subnet_ids` の出力を map 反復 (辞書順) から
`local.azs` 順に直した — compute が AZ を指定しないときの既定が
辞書順先頭ではなく第一希望になるようにするため。

- **リストの順序は CIDR に効く**。subnet の CIDR はリスト位置から
  `cidrsubnet` で決まるので、並べ替えると全 subnet が replace される。追加は安全

### インスタンス選定の再評価 (2026-08-20)

sibling repo が公開リファレンス出力 (`bhns_gw230529.out` の Carpet ログと
SLURM エピローグ) を直読みして数値を訂正した。**本 repo が使っていた
「256 コア / 30 時間 / 140 GB」は 3 つとも誤り**だった。

| 項目 | 旧 (本 repo の記述) | 実測 (2026-08-20) |
| --- | --- | --- |
| 並列度 | 256 cores | **480 rank** (12 ノード × 40 コア) |
| 実行時間 | 30 時間 | 46.4 h で t=3041 M / t=2000 M まで約 30.5 h |
| core-hours | — | **約 14,600 core-hours** (t=2000 M) |
| メモリ | 140 GB | **438.5 GB** (12 ノード合計、SLURM 申告) |
| 速度 | — | 3.30 sec/iter (dt = 0.06 M) |
| 合体時刻 | — | t ≈ 713 M (ψ4 ピーク 1213 M − 抽出半径 500 M) |

140 GB の出所は sibling 側でも特定できず、**もう使わない**ことにした。

**メモリが律速で、価格ではない。** 438.5 GB は 480 rank 時の全ノード合計。
192 rank なら ghost zone の重複が減るぶん下がるが、chunk の体積が 2.5 倍でも
線寸は 1.36 倍にしかならず、ghost 比は線寸に従うので下げ幅は弱い。
SLURM の値を一番甘く 10 進 GB (= 408 GiB) と読んでも、**削減を当てる前から
c7a.48xlarge の 384 GiB を超えている**。

物理コア単価 (us-west-2d spot、2026-08-20 実測):

| タイプ | 物理コア | メモリ | ch | USD/h | USD/物理コア時 |
| --- | --- | --- | --- | --- | --- |
| c7a.48xlarge | 192 Genoa 3.7 GHz | 384 GiB | 12 | 2.978 | **0.0155** |
| m7a.48xlarge | 192 Genoa 3.7 GHz | 768 GiB | 12 | 3.747 | 0.0195 |
| r7a.48xlarge | 192 Genoa 3.7 GHz | 1536 GiB | 12 | 4.220 | 0.0220 |
| c7i.48xlarge | 96 SPR 3.2 GHz + HT | 384 GiB | 8 | 3.072 | 0.0320 |
| c7a.24xlarge | 96 Genoa 3.7 GHz | 192 GiB | 12 | 1.950 | 0.0203 |

- **m7a.48xlarge を既定にした**。768 GiB が単一ノードで唯一余裕のある値。
  コア単価 +26% は OOM で run を失うリスクに対して安い保険
- **c7a.48xlarge はコア単価最良**。Phase 5 が working set を 384 GiB から
  十分下回ると実測したときだけ本番タイプに昇格する
- **r7a.48xlarge (1536 GiB) を scout に追加**。768 GiB でも足りなかった場合の逃げ道
- **c7i.48xlarge を scout から除外**。時間単価が c7a の 3% 差に見えるのが罠で、
  物理コア単価は **2.06 倍**。メモリ 8ch / 3.2 GHz も不利。
  これ以上測っても比は変わらないので候補から落とした
- **小さくする案は成立しない**。c7a.24xlarge は 192 GiB でフル解像度が載らず、
  しかも 48xlarge より物理コア単価が 31% 高い

**コスト見積り**: 14,600 core-hours ÷ 192 コア = 参照ノードと per-core 同等なら
76 時間。Genoa 3.7 GHz / DDR5 12ch で 1.5–2 倍と見て **38–76 時間**:

| | 38 h | 51 h | 76 h |
| --- | --- | --- | --- |
| c7a.48xlarge @ 2.978 | 113 USD | 152 USD | 226 USD |
| m7a.48xlarge @ 3.747 | 142 USD | 190 USD | **285 USD** |

悲観端 (m7a × 参照同等) は 300 USD 枠を使い切る。逃げ道は
**合体が t≈713 M なので 2000 M ではなく ~1500 M で打ち切る** (約 25% 節約、
ringdown は余裕で収まる)。ただしこれは物理側の判断なので Phase 5 の実測待ち。

本 repo の run 長依存の数値 (checkpoint 世代数、S3 常駐量、gp3 スループット費)
は**すべて悲観側の 76 時間で見積もり直した**。

### checkpoint 同期の設計 (2026-08-20 決定)

本体 repo の Phase 2 実測 (checkpoint 25 GB @ dx=28 → フル解像度 78 GB) を
受けて確定。詳細は `docs/architecture.md`「Checkpoint synchronisation」。

- **slot-a / slot-b の 2 面交互書き + `CURRENT` マーカー**。
  push-only mirror だと 76 世代 = 5.9 TB / 約 31 USD (予算の 10%) 溜まる。
  2 面なら (保持世代数 × 78 GB) × 2 slot = 既定の keep=2 で **312 GB** 固定
- **`CURRENT` はアップロード成功後にのみ書く**。78 GB の転送中に中断されると
  S3 に不完全なセットが残り、`recover = autoprobe` は「最新だから」それを
  選んでしまう。タイムスタンプではなくマーカーで復元先を決めるのはこのため
- **checkpoint 1 時間 / sync 5 分**。78 GB の書き込みは全 rank を 78 秒
  止めるので、間隔を半分にすると wall clock の 4.3% を失う。
  76h run で確定 約 1.6 時間の節約 vs 中断 1 回あたり約 15 分の追加ロス
- **同一リージョンの転送料は 0**。残るのは PUT リクエスト (checkpoint 1 回
  約 $0.05) と保管料 (312 GB × 1 週間で約 $1.7) のみ
- sync は変更が無ければ LIST のみで終わるので、間隔を短くしても実質無料

### シミュレーション repo Phase 1–2 の実測を受けた対応 (2026-08-20)

sibling repo の Phase 1 (Docker ビルド) / Phase 2 (ローカル smoke) から
申し送られた 3 点に対応済み。詳細は `docs/architecture.md`。

1. **Phase 4 は物理計算をしない (`run_mode = "ops-rehearsal"`)**

   `c7a.2xlarge` は 16 GiB で、**収まって かつ 走る解像度が存在しない**:

   | dx | メモリ | 16 GiB に収まるか |
   | --- | --- | --- |
   | 28.0 | 37.1 GB (実測) | 入らない |
   | 33.6 | 21–26 GB (推定) | 入らない |
   | 67.2 | 11.6 GB (実測) | 入るが evolution 1 歩目で NaN |

   dx=67.2 が落ちるのは解像度ではなく構造の問題。`Carpetregrid2::radius_*[N]`
   が M 単位で固定なので、dx を粗くしても**ボックスの物理サイズは変わらず
   セル数だけ減る**。level 1 が上流 62 セルに対し 17 セルしかなく、
   ghost_size=3 と prolongation buffer を引くと有効領域が消える

   代案の `c7a.8xlarge` (64 GiB) は Phase 4 予算 ($5–15) の大半を、
   捨てる出力のために使うことになる。**Phase 4 の目的は ops ループの検証**
   なので、rank ごと 1 ファイルの合成ペイロードを吐いて slot 回転 /
   `CURRENT` / 中断フラッシュ / 復元を検証する方式にした。物理は Phase 5 から

2. **parfile と FUKA 初期データは S3 の `inputs/` から取得する**

   上流ギャラリー著作物なので repo にも**イメージにも入れない**
   (シミュレーション repo は `upstream/` を gitignore + `.dockerignore` で
   ビルドコンテキストからも除外している)。ローカルで動いていたのは
   repo 全体を bind mount していたからで、クラウドには mount 元が無い。
   4 ファイル 1.6 MB を `make upload-inputs` で private バケットに置く。
   **ECR に焼かないのは、公開設定を誤ったときに著作物の再配布になるため**

   `.info` の `eosfile` は絶対パスなので user-data 側で `sed` して書き換える。
   **注意: このキーは行頭ではなくインデントされている**。`^eosfile` では
   マッチしないので `^[[:space:]]*eosfile` を使うこと (実ファイルで検証済み)。
   書き換えが効かなかった場合は起動時に fail-fast する

3. **checkpoint の mount 先を parfile に合わせた**

   parfile の `IO::checkpoint_dir = "../CHECKPOINTS"` は run の cwd 相対。
   parfile を触らず、mount 先を
   `$WORK/checkpoints:/home/etuser/simulations/<run_name>/CHECKPOINTS`
   にした (simulations mount の内側にネストさせる)。
   ホスト側では別ディレクトリのままなので、sidecar が checkpoint と output を
   区別できる。output sync 側にも `--exclude '*/CHECKPOINTS/*'` を保険で入れた

   **`run_name` は解像度を含めること**。checkpoint_dir が相対なので、
   親ディレクトリを共有すると `recover = autoprobe` が別解像度の checkpoint を
   拾う

   併せて `IO::checkpoint_ID = "yes"` を parfile 必須設定として記録。
   FUKA ID import は 24.9 分 (ローカル実測) かかり OpenMP 非対応なので、
   これが無いと**中断のたびに払う**ことになる

- 【解消】np≥2 の checkpoint 挙動は Phase 2 で確定 (np=16 で POSIX lock
  エラーゼロ、rank ごと 1 ファイル)。公式と同じ pure MPI 構成で問題ない
- 【入れ違い】申し送りノートの「`sync_interval_minutes = 20` は妥当」は、
  同日先行して 5 分 + slot 方式に変更済みのため superseded

### 未確定 / 保留

- 【解消】**checkpoint からの recover 実証** — sibling の Phase 2 で完了。
  `recover = "autoprobe"` が `it_256` を自動で拾い、**Kadath import 実行 0 回**。
  recover 読み込み + 終了時 checkpoint で 94 秒、cold start の 2065 秒に対し
  33 分の節約。spot 中断からの復帰は成立する
- **【要対応】`IO::checkpoint_keep` は run をまたいで効かない** — sibling の
  Phase 2 で 2 run 後に 3 世代 77 GB が残った。フル解像度は 1 世代 78 GB なので
  `root_volume_size_gb = 500` は **6 世代で埋まる**。中断→再開を数回やれば届く。
  slot 方式が固定するのは **S3 側だけ**で、EBS 側は別途刈る必要がある。
  sidecar に「`CURRENT` が指す世代と書き込み中の世代以外を消す」処理を入れる。
  `templates/user_data.sh.tftpl` に `TODO(phase5)` として記録済み
- **【要対応】本番インスタンスタイプは Phase 5 のメモリ実測で確定する**。
  np=192 で単一ノードに載らない場合、マルチノード MPI は
  「学習目的の選択肢」から**必要条件**に格上げされる
- **78 GB は dx=28 の 25 GB からの外挿**。フル解像度の実測は Phase 5 待ち。
  `root_volume_size_gb` と slot 設計はこの値に依存している
- **IAM ユーザー `gw230529` に `policies/terraform-operator.json` を付与する**
  【2026-08-20 完了: `make check-permissions` で 109/109 allowed を確認済み】

  経緯 (2026-08-19〜20):
  1. 6 つの managed policy (EC2/S3/ECR/IAM/SNS/EventBridge FullAccess) を付与
     → budgets / ce / ssm / servicequotas が不足 (97 中 16 deny)
  2. 名前スコープ型のインラインポリシーに差し替え
     → s3/ec2/rds/dynamodb/lambda のみになり、ecr/iam/sns/events/budgets/ce/ssm
     が丸ごと欠落 (bootstrap は通るが foundation と compute が全滅)
  3. → **スコープ方針を維持したまま不足分を補った完成版**を作成。
     `make check-permissions-policy` で **109/109 allowed** を確認済み

  設計上の要点:
  - スコープ可能なサービスは `gw230529-*` で絞る (S3 / ECR / IAM / SNS /
    EventBridge / Budgets / SSM パラメータ)
  - **EC2 は名前でスコープできない**。ARN にプロジェクト名が入らないため、
    `arn:aws:ec2:*:*:*/*` のようなパターンは**全 EC2 リソースにマッチする**。
    「絞ったつもり」が一番危ない
  - 代わりに**破壊的 EC2 アクションに tag 条件付きの明示 Deny** を置く。
    `aws:ResourceTag/Project != gw230529` なら explicitDeny。
    provider の `default_tags` が全リソースに Project を打つので自分のものは
    消せる。検証済み: 自分=allowed / タグ無し=explicitDeny / 他=explicitDeny
  - `ce:*` / Session Manager / `ec2:GetSpotPlacementScores` などは
    AWS 側にリソースレベル権限が無いので `*`。README に理由を明記
  - `iam:AttachUserPolicy` / `iam:CreatePolicy` を含めないので、
    **このユーザーは自分を admin に昇格できない** (旧 `IAMFullAccess` 構成には
    無かった性質)
- **user_data の Phase 4 TODO** — シミュレーション起動コマンドは
  本体 repo の Phase 2–3 (ローカル dx=28 run) でマウント構成と np≥2 の挙動が
  確定してから埋める

## 言語設定

このプロジェクトでは**日本語**での応答を行う。ただし以下は**英語必須**。

**英語必須** — リポジトリにコミットされる成果物の中身:

- `*.tf` / `*.tftpl` のコメントと `description`
- `Makefile` / `makefiles/*.mk` のコメント、ヘルプテキスト (`## コメント`)、`echo` 出力
- `scripts/*.sh` のコメントとメッセージ
- `README.md`, `docs/*.md`
- `.env.example`, `*.tfvars.example`, `backend.hcl.example` のコメント
- コミットメッセージ

**日本語で可** — 人間が読む記録:

- `CLAUDE.md` (本ファイル)
- `.claude-notes/` のセッションノート
- チャット上の応答

**重要**: 他リポジトリからファイルをコピーして流用する場合も、
**コピー元の日本語コメントは必ず英語に書き換える**こと。

## 開発ルール

### Terraform 規約

- 変数・出力・リソース名: snake_case
- すべての変数に `description` を書く。単位と既定値の根拠を含める
- **なぜその選択なのかをコメントに残す**。特にコストを理由に却下した代替案は
  必ず書く (後から「なぜ NAT を使わないのか」を再発見させない)
- モジュールは `main.tf` / `variables.tf` / `outputs.tf` / `versions.tf` に分割
- provider は `~> 6.0` で固定、`.terraform.lock.hcl` はコミットする
- コミット前に `make check` (fmt-check + validate + check-secrets)

### 秘匿情報の扱い

gitignore 済み: `*.tfvars` / `*.tfstate*` / `backend.hcl` / `.env` / `.terraform/`

- backend は **partial configuration**。`terraform init -backend-config=backend.hcl`
- 追跡ファイルに 12 桁数値・ARN・`AKIA` が入ると `make check-secrets` が落ちる
- **アカウント ID の秘匿は多層防御であって境界ではない**。境界は IAM。
  この仕組みは `terraform output` の貼り付け事故を止めるためのもの

### Terraform で完結しない手作業

1. **SNS subscription の確認** — apply 後、2 通の確認メールの
   「Confirm subscription」をクリック (すぐ下の解除リンクではない)。
   購読は**あとから 1 クリックで消える**。SNS が送る全メールに解除リンクが
   付いていて、消えても Terraform の state 上はリソースが残るので誰も気づかない。
   気づくのは「鳴るべきときに鳴らなかった」瞬間。
   `make check-alerts` で実際に配信できるかを検査でき、`make run` は
   どちらかが無効なら**課金を始める前に停止する** (`SKIP_ALERT_CHECK=1` で回避可)
2. **コスト配分タグ `Project` の有効化** — Billing コンソール。有効化するまで
   タグフィルタは何にもマッチしないので、`cost_allocation_tag` は既定で null
   (アカウント全体を対象にする方が安全)
3. **spot vCPU クォータ緩和** — `L-34B43A08` を 192 以上に

## Git運用

- ブランチ戦略: feature/*, fix/*, refactor/*
- コミットメッセージ: 英文を使用、動詞から始める
- PRはmainブランチへ

### コミット粒度

- **1コミット = 1つの主要な変更**
- **論理的な単位でコミット**
- **段階的コミット**

### プレフィックスと絵文字

- ✨ feat: 新機能
- 🐞 fix: バグ修正
- 📚 docs: ドキュメント
- 🎨 style: コードスタイル修正
- 🛠️ refactor: リファクタリング
- ⚡ perf: パフォーマンス改善
- ✅ test: テスト追加・修正
- 🏗️ chore: ビルド・補助ツール
- 🚀 deploy: デプロイ
- 🔒 security: セキュリティ修正
- 📝 update: 更新・改善
- 🗑️ remove: 削除

**重要**: Claude Codeを使用してコミットする場合は、必ず以下の署名を含める：

```text
🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## ドキュメント更新プロセス

機能追加や Phase 完了時には以下を同期更新する:

1. **CLAUDE.md**: 設計判断の確定・保留状況
2. **README.md**: 手順とコストモデル
3. **docs/architecture.md**: 構成図と根拠
4. **Makefile / makefiles/**: ヘルプテキスト (`## コメント`)
