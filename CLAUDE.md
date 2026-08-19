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
| インスタンス | **c7a.48xlarge**。フォールバックは m7a.48xlarge | c7i は 192 vCPU = 物理 96 コア + HT、メモリ 8ch。実質半分の機械 |
| state backend | S3 + native lockfile (`use_lockfile`) | DynamoDB テーブルが不要になる |
| S3 構成 | 1 バケット + prefix 別 lifecycle | バケット分割は分離を買わずポリシー面だけ増える |
| ネットワーク | public subnet + IGW + S3 Gateway Endpoint | private + NAT は月 33 USD、予算の 11% |
| スタック分割 | bootstrap / foundation / compute の 3 つ | **環境別ではなく寿命別**。compute の destroy がデータに届かない |
| spot instance | `aws_instance` + one-time spot、`run_enabled` フラグ | 中断後の再開が `terraform apply` 1 発になる |

### リージョン選定の実測結果 (2026-08-19、`make region-scout`)

target 192 vCPU / single-AZ / c7a・m7a・c7i の 48xlarge で計測。

| リージョン | score 9 の AZ 数 | c7a.48xlarge 最安 | spot vCPU クォータ |
| --- | --- | --- | --- |
| us-west-2 | 4 中 3 | 2.970 USD/h (us-west-2d) | 256 |
| us-east-1 | 6 中 4 | 2.996 USD/h (us-east-1a) | 256 |
| us-east-2 | 3 中 2 (1 つは 6) | 2.572 USD/h | **5** |

- **us-east-2 は脱落**。約 15% 安いがクォータが 5。緩和申請の承認待ち
  (数時間〜数日) に見合う差ではない (30 時間 run で約 13 USD)
- **us-west-2 を採用**。容量では差がつかない (どちらも score 9、クォータ済み)。
  決め手は**フォールバック AZ の価格が近い**こと:
  us-west-2 は 2.97 → 3.05 → 3.32、us-east-1 は 2.996 → 3.49 → 3.52。
  第一希望の AZ を外されたときの傷が浅い。加えて us-east-1 は
  AWS 全体の大規模障害が集中する
- **クォータ緩和申請は不要だった** — us-east-1 / us-west-2 は既に 256 vCPU。
  当初の「今すぐ申請」という申し送りは解消

### checkpoint 同期の設計 (2026-08-20 決定)

本体 repo の Phase 2 実測 (checkpoint 25 GB @ dx=28 → フル解像度 78 GB) を
受けて確定。詳細は `docs/architecture.md`「Checkpoint synchronisation」。

- **slot-a / slot-b の 2 面交互書き + `CURRENT` マーカー**。
  push-only mirror だと 60 世代 = 4.7 TB / 約 25 USD (予算の 8%) 溜まる。
  2 面なら 156 GB 固定
- **`CURRENT` はアップロード成功後にのみ書く**。78 GB の転送中に中断されると
  S3 に不完全なセットが残り、`recover = autoprobe` は「最新だから」それを
  選んでしまう。タイムスタンプではなくマーカーで復元先を決めるのはこのため
- **checkpoint 1 時間 / sync 5 分**。78 GB の書き込みは全 rank を 78 秒
  止めるので、間隔を半分にすると wall clock の 4.3% を失う。
  30h run で確定 38 分の節約 vs 中断 1 回あたり約 15 分の追加ロス
- **同一リージョンの転送料は 0**。残るのは PUT リクエスト (checkpoint 1 回
  約 $0.05) と保管料 (156 GB × 3 日で約 $0.36) のみ
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

- **checkpoint からの recover 実証** — シミュレーション repo 側で進行中。
  ID import をスキップできることが実証されたら本 repo にも反映する
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

1. **SNS subscription の確認** — apply 後、2 通の確認メールのリンクをクリック
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
