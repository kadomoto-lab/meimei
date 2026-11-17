# CLAUDE.md — meimei（8-wide アウトオブオーダ RV64IMFDC_Zicsr コア）

将来、VCA（Value-Centric Architecture）コア Mumei と比較する予定だが、Mumei は**別リポジトリ**で開発する。
このリポジトリは従来型（rename + PRF）のアウトオブオーダコア単体。

## このプロジェクトは何か
固定プログラムを動かすベアメタル用のアウトオブオーダ RV64IMFDC_Zicsr コア（SystemVerilog、独自実装）。

- ISA: RV64I + M + F + D + C + Zicsr。特権機構・MMU・I/O・例外は入れない方針（OS は動かさない）
  - CSR は fflags / frm / fcsr と読み出し専用 cycle / time / instret のみ。他の番地は読むと 0、書込は無視
  - A / Zifencei は未実装
- メモリ: 理想メモリ（キャッシュなし）。命令 SRAM はフェッチブロック分をバンクから非同期に 1 サイクルで読む。
  データ SRAM は 2 バンク（アドレス bit3）× ロードポート数の写しで、AGU のアドレスで同期読み出し（FPGA の BRAM）
- 既定は 8-wide。`+define+MM_SMALL` で 4-wide 構成
- 識別子の接頭辞は `mm_` / `MM_`（2026-10-31 に旧接頭辞から改名）

**方針: 独自路線で性能（IPC と周波数）を伸ばし、FPGA 実機で評価する。** 他のコアの構成に合わせることは目標にしない。
変更は「狙いと根拠の整理 → mm_pkg のスイッチ付きで実装 → 回帰テスト → 同じプログラムで IPC 比較 →
（タイミングに関わるなら）synthfast」の順で行い、結果をこのファイルに記録する。
ドキュメント・コメントで他のプロセッサ実装を設計の根拠として引用しない（設計の説明はこのコア自身の言葉で書く。
TAGE / StoreSet / SRT など学術的な手法名は可）。

## ディレクトリ
```
rtl/
  mm_soc.sv        SoC トップ（コア + 命令/データ SRAM + UART/GPIO/タイマ・実行状態、メモリマップは下記）
  mm_pkg.sv        全パラメータ・スイッチ・型・リングポインタ関数（rob_add/rob_dist/rob_older, lq_*, sq_*）
  cpu_pkg.sv       RV64I の opcode / ALU コード / load-store 型（eeic-vlsi/SynRV 由来、Apache-2.0）
  decoder.sv alu.sv  RV64I デコーダと ALU（eeic-vlsi/SynRV 由来、Apache-2.0）
  rvc.sv           RVC 展開器（IFU で 16 bit 命令を 32 bit に展開）
  mm_decode.sv     RV64IMFD_Zicsr デコード（decoder.sv + M/F/D/CSR、frm で動的丸めを解決）→ dec_t
  muldiv.sv        MUL（3 段 Booth + CSA パイプライン、MUL_PIPE）/ DIV（SRT、DIV_SRT。旧版は SynRV 由来の引き戻し法）/ mm_lzc / mm_csa_rows
  fpu.sv           fp_unpack / fp_round / fp_fma(+unit, pipe) / fp_misc / fp_i2f / fp_divsqrt（独自実装、IEEE 754 S/D）
  frontend.sv      BPU(s1 uBTB+micro-RAS / s2 BTB+TAGE / s3 ITTAGE+RAS(+SC)) -> FTQ -> IFU -> IBuffer
  issue_queue.sv   発行キュー（2 enq、年齢行列の oldest-ready select、wakeup、flush、書き込みポート予約、反復器ブロック）
  mm_wbpipe.sv     固定レイテンシユニットの遅延書き込み + 早期 wakeup
  mm_core.sv       rename/dispatch, ROB, PRF, レジスタキャッシュ, ALU/BJU/MUL/DIV/I2F/FEX/FDIV/LDU/STA/STD, LQ/SQ/RAW/リプレイ/ストアバッファ, redirect, commit
  mm_freelist.sv   物理レジスタのフリーリスト（循環キュー）。int / FP に 1 個ずつ
  mm_mem.sv        mm_imem（NSLOT ワードバンク、ブロック単位読み出し）/ mm_dmem（2 バンク、同期読み出し + 同サイクル書込バイパス）
tb/
  tb.sv            テストベンチ（コミットトレース、最終状態ダンプ、イベント統計 stats.txt）
  gen.py           乱数プログラム生成器（通常 / loop / fp / fpcsr / fploop / rvc、+c で RVC 再配置）+ Python ISS
  rvc.py           RVC の展開（ISS）と圧縮（生成器の再配置）
  cmp.py           ISS と RTL の比較（cycle/time 読み出しは "?" で任意値と一致）
  fpmodel.py       ISS の FP 演算（整数で厳密計算 → 1 回丸め。RTL とは独立の実装）
  run.sh           Verilator ビルド + 差分テスト
  prun.sh          run.sh の並列版（ビルドはしない。STATS=1 で stats.txt を合計表示）
  xcheck_unicorn.py    ISS 自体を Unicorn で検証（整数プログラム）
  xcheck_fp_unicorn.py fpmodel と M を命令単位で Unicorn（QEMU softfloat）と比較
  fpu/             FPU 単体テスト（fpu_vec.py でベクタ生成 → fpu_tb.sv）
sim/
  tb_soc.sv        SoC テストベンチ（code.hex/data.hex をロード、UART 表示、EXIT で終了、+TRACE でコミットトレース、+PERF で性能カウンタ）
  perf.svh         性能カウンタ（コミット/リネーム停止の内訳、発行キュー満杯のクラス、redirect、読み出しポート、ストアバッファ等）
  Makefile         make build/run/check/test/coremark（CONFIG=small|full）
  run_tests.sh     C テストを全部走らせ UART 出力をホストのゴールデン出力と比較
  rvsim.py         SoC 用 ISS（tb/ の ISS 部品を利用）。RTL のコミットトレースとロックステップ照合
fpga/              Nexys Video（XC7A200T）用: rtl/mm_fpga_top.sv（MMCM, UART, LED）, nexys_video.xdc,
                   build.tcl（Vivado 非プロジェクトフロー）, run_vivado.sh（WSL から Windows の Vivado を起動）,
                   split_hex.py（プログラムイメージをメモリバンク別の hex に分割）
asic/              sv2v → Yosys → ASAP7 → OpenSTA の段の深さ評価（配置配線なし）
software/          ベアメタルソフト（詳細は software/README.md）
  software_tools/  Makefile.inc, link.ld, crt0.S, syscalls.c（newlib）, soc.h, elf2hex.py
  hello/ tests/ coremark/
docs/block_diagram.svg   README 冒頭のブロック図。docs/block_diagram.py で生成（構成を変えたらスクリプトの数値を直して再生成。
                         フォントは docs/fonts/ の Nunito サブセット（OFL）を SVG に埋め込み）
docs/logo.png, logo-dark.png   README 冒頭のロゴ（logo.png は原画のまま。dark はパレットの dark_main / dark_accent で塗り替え）
README.md          構成説明（英語）
LICENSE            Apache-2.0（eeic-vlsi/SynRV から継承）
```

## 現在の構成（mm_pkg.sv）
| 項目 | 8-wide（既定） | 4-wide（MM_SMALL） |
|---|---|---|
| fetch block / FTQ / IBuffer | 64B = 32 ハーフワードスロット（RVC）/ 64 / 48 | 32B / 16 / 32 |
| decode/rename/commit 幅 | 8 | 4 |
| ROB / int PRF / FP PRF | 352 / 224 / 256 | 64 / 96 / 96 |
| LQ / RAW キュー / SQ / ストアバッファ | 120 / 56 / 128 / 16 ライン × 16 B | 16 / 8 / 16 / 16 × 16 B |
| 実行ユニット | ALU 6（うち BJU 付き 3、MUL は ALU4/5、DIV は ALU1、I2F は ALU2）, LDU 3, STA 2 + STD 2, FEX 4（全て FALU+FMA、FEX0 に FCVT/FCMP、FEX1/2 に FDIV） | ALU 4（BJU 2）, LDU 2, STA 1 + STD 1, FEX 2 |
| 発行キュー | ALU+BJU 18, ALU 20, LDU 20, STA 16, STD 16, FEX 20（各 2 enq） | 各 12 |
| レイテンシ | ALU 1, MUL 3, I2F 3, FALU 2, FMA 4, FCVT 4, DIV/FDIV SRT 反復（4 bit/cycle、DIV は商の桁数で可変） | 同じ |
| 整数 PRF 読み出しポート | 12 を優先度付きで共有 | 8 |
| レジスタキャッシュ | ALU 24 + リンク 6 + ロード 12 | 16 + 4 + 8 |
| 分岐予測 | uBTB 32、BTB 32 セット × 32 バンク、TAGE 4 × 1024（タグ 10 bit）、ITTAGE 3 × 64、RAS 16 | BTB 16 バンク |

パイプライン（ALU 命令、最短 12 段）:
`BP(s1) | F0 | F1 | F2 | DE | RN | DP | IS | RR | EX | WB(PRF書込・ROB完了) | CM`

### フロントエンド
- BPU は 3 段の上書き型。s1: uBTB（32、ブロック先頭で引く全連想、s2 の予測で学習）+ micro-RAS で泡なしの次ブロック。
  s2: BTB（スロットごとのバンク、バンクごとに 1 回読み）+ TAGE（4 表 × 1024 = 512 セット × 2 ウェイ、タグ 10 bit、パス履歴）で上書き
  （泡 1）。s3: ITTAGE（3 表）と主 RAS で上書き（泡 2）。SC は実装済みだが既定 OFF（IPC が悪化したため）
  - s2 用の BTB/TAGE 行と TAGE タグハッシュは FTQ 投入サイクル（s1）に読んで登録、ITTAGE 行は s2 で読んで s3 へ。
    s2/s3 はブロック先頭・履歴・RAS 位置・元の予測を段ごとのレジスタで持つ。上書きによる IFU の flush は 1 サイクル後
  - BP_PRE: 各バンクのスロット位置・TAGE チャンク・期待タグ・TAGE のタグ比較と方向、ブロック先頭上位 + 1 を s1 で求めて登録。
    s2 は登録済みの方向から最初の taken を狭いベクタで求め、CFI / リンクアドレスはバンクごとの下位を並列に計算して
    キャリーセレクト。s3 は s2 の判定を受け取り RET / JALR のターゲットだけを作る。sim 専用で旧 s3 の計算と毎サイクル照合
  - 上書き時の次 PC（ブロック先頭 + 64 B）は s1 で求めて段ごとに登録、s3 のターゲット比較は候補（BTB / ITTAGE の
    provider / alt / RAS）ごとに並列に行って選ぶ
  - s2 の上書き判定は taken と位置だけ（S2_TGT_CMP=0）。ターゲットの違いは s3 が検出
  - TAGE / ITTAGE はフェッチブロックの半分に整列したチャンクで索引し、チャンク内位置をタグに XOR（BP_IDX_MODE=2）。
    1 ブロックで表あたり 3 行読むだけ。ブロック先頭索引（BP_IDX_MODE=1）は小さい表では同じ分岐が散り CoreMark −2%。
    チャンクの行アドレス（ブロック先頭の行 + r）は bpu_pc を書くときに求めて一緒に登録する（BP_LINE_PRE。s1 の索引・タグの
    ハッシュがレジスタから始まり、表の読み出しの前に加算器がない。sim 専用で bpu_pc から求めた値と毎サイクル照合）
  - BTB / ITTAGE のターゲットは 20 bit（2 B 単位）で、上位はブロック先頭から（BP_TGT_START）
  - RAS: 主 RAS は s3 を出る各ブロックの最終予測でだけ push/pop し、復元用の RAS ポインタも s3 で FTQ に記録（RAS_S3）。
    s1 は micro-RAS（s2/s3 にいるブロックの push/pop と push アドレスを追い、次の s1 が見る先頭値と「使えるか」を
    レジスタで持つ）を使い、使えないときは BTB/uBTB の記録値。push は 1 サイクル後に書き、読み出しは書込バイパス付き（RAS_WDELAY）
  - 予測器の表は SRAM で実装できる形（索引を計算 → 次段でデータ）。学習はコミットした CFI を 16 段の学習キューに入れ
    1 本/cycle、U0（索引・タグを登録して表を読む）→ U1（書く）（TRAIN_STAGE / TRAIN_SRAM）。有効ビット・有用度ビットと uBTB はフリップフロップ。
    TAGE のタグとカウンタは表ごと・欄ごとの 1 次元配列で書込ポート 1 本（学習は 1 サイクルに表あたり 1 エントリしか書かない。
    書込の判定は学習の組合せ回路で求める）、読み出しは s1 の NCHK 行と U0 の 1 行の組合せ読み（TAGE_RAM）。FPGA では分散 RAM になる
    （2 次元配列 [表][エントリ] のままだと Vivado は FF と読み出しの mux にする: 単体の試験で 48k LUT + 41k FF 対 8.5k LUT）。
    sim では同じ内容を t_tag / t_ctr にも書き、参照実装 predict() との照合に使う
    TAGE / ITTAGE の有用度ビットも U0 で他の行と一緒に読んで登録し、U1 の割り当て連鎖はレジスタから始まる（TRAIN_U_REG。
    直前の学習が同じ行に書いた値は古いまま読む）
  - sim 専用の自己検査: s2 の結果をスロット順の参照実装 predict() と毎サイクル比較（不一致は $error）
- FTQ（64）がブロック先頭 PC を持ち、uop は (ftq_idx, off) だけを運ぶ（PC・予測ターゲットを uop に載せない）。
  予測器学習用の分岐ターゲットも ROB ではなく FTQ エントリ単位（ftq_rtgt）
- IFU は 3 段 + WB（理想メモリなので命令メモリの読み出しは F0 の 1 段）:
  F0: FTQ の ifu_ptr を取り命令メモリのバンクを読む → F1: 命令境界（前ブロックの最後の 32 bit 命令の後半を含む。
  1 bit 連鎖、後半はキャリーセレクト）・RVC 展開・順位での圧縮・PC → F2: プリデコードチェック（未予測 JAL、非 CFI の taken。
  スロットごとに並列に判定して最初の不一致を優先エンコーダで選ぶ。JAL のターゲットは比較しない: IFU_JAL_TGT_CHK=0）、
  切った所までを IBuffer へ → WB: IFU redirect を BPU / FTQ に適用し F0〜F2 の後続ブロックを捨てる。
  BPU s2/s3 の上書きは対象ブロック以降を F0/F1 から捨てて取り直す（s3 の判定はブロックが F2 に届く前に終わる）
- RVC: BTB はスロット（2 バイト）単位のバンク、予測オフセットもスロット。最大 32 命令/サイクルで IBuffer へ。
  最終スロットから始まる 32 bit 命令は 1 ハーフワード余分に読んでそのブロックで渡し、次の連続ブロックは先頭ハーフワードを
  飛ばす（ftq_cross: F1 で暫定値、IFU redirect 時に WB で確定値）
- IBuffer は空き ≥ 1 ブロック分（レジスタの件数だけ）で受け付け、全スロットを書いて件数だけチェック結果で増やす。
  書込は 4 バンク（IFU で事前整列）

### リネーム・ディスパッチ
- DE / RN / DP は別段。DE: IBuffer 出力をデコードして DE バッファ（2 グループ分の循環キュー、補充量はサイクル開始時の空きで決める）へ。
  RN: RAT・フリーリスト・ROB/LQ/SQ 割当・スナップショット・StoreSet、動的丸めモード（frm）もここで解決。IQ の選択もここで計算して
  DP グループと一緒にレジスタへ。DP: グループを IQ へ順に投入（同じ IQ 宛ての残り uop の順位 < 2 かつ < IQ 空き）、
  オペランドの準備状態は busy table をここで読む。RN→DP は DP グループが全部出るサイクルだけ次のグループを受け取る。
  詰まったグループは残りの uop の IQ を選び直す。redirect で DE / DP は全部捨てる
- リネームのグループ受理（REN_GROUP_ACC）: 各資源の空きを DE グループ全体の必要数と比較。pdest・LQ/SQ ポインタ・IQ の
  選び先の添字は「受理されるなら」の前置で数える。IQ 空き判定は「前サイクルの空き − 前サイクルの投入数」を登録した下限値
- ディスパッチは各クラスの IQ を占有数の少ない順に選ぶ（IQ_BALANCE）
- int と FP の物理レジスタは 1 つの番号空間（int が先頭）だが、レジスタファイルは int / FP で物理的に別
  （prf_i / prf_f。sim 用に合成ビュー prf）。フリーリストはクラスごとの循環キュー（割当は head から、解放はコミット順に
  tail へ、walk は head を戻す、スナップショットは head ポインタだけ保存）。RAT は 64 本（x0..x31, f0..f31）
- リネームスナップショット 4 個（SNAP_EN/SNAP_FWD/SNAP_DIST=0）: 分岐ミスは直近の古いスナップショットから復元し、
  必要なら前向き walk。なければ ROB を末尾から後ろ向き walk（残り数との定数比較で各スロットを決める: WALK_PAR、
  sim 専用で直列版と照合）。前向き walk 中は未再適用の ROB 項目のコミットを止める。スナップショット後にコミットで解放された
  preg は全スナップショットの free にも立てる（さもないと誤経路で再割当てされた preg が漏れる）。
  復元するスナップショットは one-hot で選ぶ（SNAP_SEL_OH）: 「最後に残る命令以前」は redirect に kill されないことと同じなので
  比較は各スナップショット 1 回、最若はスナップショット同士の順序から（redirect と無関係）。sim 専用で直列版と照合
- ムーブ除去（MOVE_ELIM）: `addi rd, rs, 0` / `add rd, x0, rs` / `add rd, rs, x0`（rd ≠ x0）はデコードで mv を立て、
  リネームで pdest = ソースの psrc（グループ内バイパス込み）。フリーリストから取らず、busy table も立てず、ROB は投入時に完了
  （rob_fflags も 0 に）、IQ には入れない。walk の割当数からも除く。解放はコミット時の古い対応を 1 段レジスタに入れ、
  翌サイクルに更新済みの arch_rat の 32 本と比較してどこからも参照されていなければ解放（同じグループの重複は 1 回）。
  空きが INT_PRF_N − 32 を超えるので整数フリーリストの容量を 2^⌈log2(INT_PRF_N − 1)⌉ にする（2 のべき乗でないと
  ポインタ演算が剰余の加算器になり 19 ns の経路になった）。sim 専用で「割り当てた preg がどの RAT にもない」を毎サイクル検査
- CSR 命令は ALU0 で、ROB 先頭になってから実行し、コミットまで後続を dispatch しない。そのため frm はデコード時に読んでよい。
  fflags は結果と一緒に ROB に書き、コミット時に OR する
- メモリ依存予測は StoreSet（SSIT 256, LFST 32、MDP_STORESET=0 で旧 load wait table）。待ち条件は「待ち先が SQ 内に生存
  && その SQ エントリが同じ ROB 番号 && ロードより古い && アドレス・データ未確定」。LFST の古いポインタ（誤経路で取り消された
  ストア等）で永久に待たないための条件で、どれが欠けてもハングした。待ちの判定は前サイクルの SQ 状態から（LD_WAIT_REG）

### 発行・レジスタ読み出し・実行
- 発行キューの oldest-ready 選択は年齢行列（エンキュー順 = プログラム順）。最古の ready エントリを one-hot で求め、発行 uop を
  AND-OR で取り出す（IQ_ONEHOT）。woken / cancelled は一致ベクタ + リダクション OR
- ENQ_DELAY: ディスパッチしたサイクルの wakeup は新エントリに直接入れず、投入 uop のソースとそのサイクルの wakeup を比較した
  結果だけを登録し、翌サイクルに入れたばかりのエントリ（2 個まで、スロットは one-hot で登録）にだけ適用する。
  選択 → wakeup → 投入 ready のループが切れる。サイクル数は完全に同一
- IQ_WK_FAST: 選択 → wakeup → ready のループを詰める。投入サイクルの wakeup（ENQ_DELAY）はスロットの one-hot から拾わず
  エントリごとのビットに登録、選んだ uop の「レイテンシ 1 で書く」は比較せずエントリごとのビットの AND-OR（wbpipe の iss_l1）、
  次の ready は (有効 && woken) | 残り（比較の結果を最後に入れる）。サイクル数は完全に同一
- 発行後は `IS | RR | EX | WB`（WB_STAGE）。RR でオペランドを PRF・レジスタキャッシュ・forward（このサイクルの固定レイテンシ
  ユニットの結果）・bypass（WB 段 = 前サイクルの結果）から選んでレジスタに置くので EX にバイパス mux はない。PRF と ROB
  （done・fflags・分岐の taken）、FTQ の学習用ターゲットは WB 段のレジスタから書く。バイパス元は固定レイテンシのポートのうち
  読み手のレジスタファイルを書くものと、ロード（LD_SPEC_WAKE: bypass だけ）。DIV・FDIV・MMIO ロードは書込時に wakeup
- ALU は発行時 wakeup（依存 ALU 命令が連続発行可能）。固定レイテンシ L のユニットは発行 +1+L サイクル目に結果を出す。
  ユニットごとに書き込みポート 1 本で、IQ が発行時にそのサイクルを予約（wbb）。依存命令は結果の 2 サイクル前に wakeup
- DIV / FDIV は反復器で専用書き込みポート。IQ は反復部が 2 サイクル後に start を受けられないとき（DIV_OVL / FDIV_OVL の acc2）
  そのクラスの発行を止める。書き込み時に wakeup
- 整数 PRF の読み出しポートは共有（IRP_ARB）: 各発行ポートのオペランドに固定のポートと優先度（mm_pkg の irp_slot）。
  発行サイクル（IS）で選ばれた uop の読み出し要求をポートごとに優先度で仲裁し、負けたオペランドがある uop は発行を取り消して
  IQ に残す（次サイクル以降に再発行）。x0、直前 2 サイクル以内に固定レイテンシで wakeup されたオペランド（bypass から取る）、
  レジスタキャッシュにあるオペランドは要求しない
- 投機的 wakeup（SPEC_WAKE）: レイテンシ 1 の uop は選択された時点で wakeup し、ポートに負けたら翌サイクルにその宛先を取り消しとして
  全 IQ と busy table へ流す。レイテンシ 2 以上は RR 段（仲裁後）から wakeup を予定する。サイクル数は SPEC_WAKE=0 と同一
- レジスタキャッシュ（REGCACHE）: ALU の書き込みポートごとに RC_DI = 4、BJU（リンク）ごとに RC_DB = 2、ロードごとに RC_DM = 4
  エントリ。整数 PRF と同じサイクルに WB 段のレジスタから書く。置き換えはポート内の second chance（書込とヒットで参照ビット、RC_REPL）。
  preg がフリーリストの割当候補に出たらそのエントリを無効化。IQ のエントリはソースごとに「キャッシュにある」ビットとエントリ番号を
  持ち（RC_TRACK）、IS では選んだエントリのビットを取り出すだけ（タグ比較なし。RC_TRACK=0 のタグ比較版と sim で毎サイクル照合）。
  キャッシュの各エントリが PRF と同じ値であることも sim で毎サイクル検査
- 分岐ミスの判定は「予測 taken ^ taken、または taken でターゲット違い」（BR_MISP_TAKEN）。次の命令への taken 分岐も
  redirect するので、taken CFI は必ず FTQ ブロックの最後になる
- 分岐は BJU パイプ（ALU0..2 の IQ の第 2 発行ポート、BJU_PORT）の EX で解決 → redirect を 1 サイクル遅らせて適用
- redirect の選択（REDIR_PAR）: MMIO replay・メモリ順序違反・BJU の候補から最古を並列の年齢比較で選ぶ。
  適用中の redirect（redir_q）による kill は候補ごとではなく選んだ最古の 1 本だけで判定する（REDIR_KILL_LATE。kill される
  候補は生き残る候補より必ず若いので結果は同じ、sim 専用で旧選択と毎サイクル照合）。MMIO replay の候補は有効判定がロードの
  生存（kill 込み）と取り込みの連鎖を通るので 1 段レジスタに入れてから候補にする（MMIO replay は 1 サイクル遅れる）。
  再実行するロードの PC は redirect をレジスタに入れた後に FTQ から読む（REDIR_PC_LATE）。StoreSet の学習も同じ PC を使う
- コミットは分岐を何本でも同時に可（学習キュー経由、MULTI_CFI_COMMIT）。学習キューの空き判定はスロットごとに独立
- 演算器:
  - MUL（mm_mul_pipe、MUL_PIPE）: EX1 Booth radix-4 の 33 行 + CSA 3 段 → EX2 CSA 4 段 → EX3 最後の 3:2 + 128 bit 加算 + 選択。
    sim 専用で組合せ版と照合
  - DIV（mm_div_srt、DIV_SRT）: start（絶対値）→ PRE（木構造 LZC、ステップ数 = LZC の差 + 1 を U の倍数に切り上げ、正規化）→
    ITER（radix-2 SRT × U、余りはキャリーセーブ、桁は上位 4 bit の見積もり、次の桁の見積もりは 3 通りを並列に
    求めて選ぶ、商は Q / QM の on-the-fly 変換）→ POST（負なら + 除数と QM、逆正規化、商 / 余りの選択）→ 結果段（符号）。
    64 bit 商で start の後 19 サイクル
    - DIV_PRE1: PRE0 / PRE1 を 1 段に。被除数は自分の LZC で正規化してから、ステップ数の U への切り上げ分（0〜U−1）だけずらす
      （シフトの前に加算器がない。U ≤ 4）。商が 0（N < D、D = 0）のときは w0 を使わず余り N を直接選ぶ
    - DIV_POST1: POST0 / POST1 を 1 段に。w と w + d を並列に足して w の符号で選ぶ
    - DIV_OVL: 結果段を反復部と分け、前の割り算が POST にいるサイクルに次を start できる。発行キューは「2 サイクル後に start を
      受けられる（acc2: IDLE / POST、または ITER の残り ≤ 2）かつ直前 2 サイクルに DIV を発行していない」ときだけ DIV を出す。
      書き込みのタグは POST で結果段用に写す
  - FDIV / FSQRT（fp_divsqrt、FDIV_SRT）: radix-2 SRT（余りはキャリーセーブ、5 bit 見積もり、S と SM = S − ulp の on-the-fly 変換、
    平方根は S0 = 1, w0 = x − 1 から: Ercegovac & Lang）。POST 段で余りの符号・sticky・正規化、FIN は丸めだけ（sim 専用で fp_round と照合）。
    結果が非正規化数になりうるとき（ITER 中に指数だけで判定）だけ DEN 段（1 サイクル）で sticky 付き右シフトをし、FIN はシフトなしの
    fp_round_fin_lim（FDIV_DEN）
    - FDIV_OVL: FIN を反復部と分け（形式・符号・丸めモード・特殊値の結果を POST で FIN 用に写す）、前の演算が POST（DEN なし）か
      DEN にいるサイクルに次を start できる。特殊値のオペランドは POST を通る（+1 サイクル）。発行キューは整数 DIV と同じく
      「2 サイクル後に start を受けられる（acc2: IDLE / POST / DEN、または ITER の残り 1、残り 2 で DEN なし）かつ直前 2 サイクルに
      FDIV を発行していない」ときだけ FDIV を出す。書き込みのタグも POST / DEN で FIN 用に写す
  - FMA（fp_fma_pipe、4 段、FMA4）: EX1 Booth 部分積 + CSA 5 段 ∥ 加数 c の桁合わせ → EX2 残りの CSA + c との 3:2 + 加減算 →
    EX3 先頭ゼロ検出 + 左シフト → EX4 丸め・特殊値
    - 桁合わせ（FMA_ALIGN_A）: 3P+1+G bit の領域に積を [2P+G-1:G] に固定、c を最上位から s = 2P+1−(ec−ea−eb) だけ右シフト
      （はみ出しは bit 0 の sticky）。s < 0 か積が 0 なら c を最上位に置き積を sticky に
    - FMA_CSA: 仮数は正規化しない（非正規化数は m × 2^emin のまま）。積はキャリーセーブの行のまま EX2 へ（27 行 + 符号拡張定数
      → CSA 5 段で 5 行を登録）。行は領域幅 mod 2^(W+1) で計算する（2P bit で打ち切ると和の桁上げが領域に漏れる）。
      正規化しない積から少し小さい c を引くとガードビットが積の LSB の 2 bit 下に来るので G = 3（W = 3P+4）。G = 2 では 1 ulp ずれる
      （tb/fpu/fpu_vec.py の「subnormal x normal」ベクタで検出）
    - FMA_LSH: EX2 で指数から左シフトの上限を one-hot に decode して登録し、EX3 は (和 | 上限) の木構造 LZC（mm_lzc）→ 左シフトで
      非正規化数を直接作る。EX4 は右シフトなしで丸めるだけ。上限が負になるのは値が 2^(emin−P−1) 未満のときだけなので sticky 1 bit
    - 加算段のシフト量は指数差 1 回の減算から直接求め、|xp-xc| は 2 つの差を並列に計算して AND-OR で選ぶ（?: や if で選ぶと
      Vivado が加算器を共有し、114 bit の桁上げ連鎖が直列に 2 本並ぶ）
    - 結果は書き込みサイクルに wbpipe の late エントリへ。sim 専用で組合せ版 fp_fma_unit と毎回照合。FPU 単体テスト（tb/fpu）も
      パイプライン版を全ベクタで照合
  - FADD/FSUB（レイテンシ 2）は FMA と別の P+3 bit の桁合わせ・加算路（正規化なしアンパック、指数の大小比較と両方向の
    桁合わせシフトを並列に行い後で選ぶ、加数はオペランド b を直接）、EX2 で専用の狭い丸め。指数差は生の指数フィールドの
    引き算だけ（FADD_RAWEXP: 非正規化数 f·2^(1−bias) を 2f·2^(0−bias) として扱うので、引き算の前に 0 判定が要らない）。
    EX2 は正規化シフトが 0 / 1 / 2 bit（桁上がり・なし・1 bit 相殺）の 3 通りを先頭ゼロ検出と並列に丸めて選ぶ（FADD_RSEL）。
    2 bit 以上の相殺は指数差 ≤ 1 のときだけで結果は正確なので、丸めずに詰める
  - FCVT 系（FCMP/FCLASS/FMV.X 含む、レイテンシ 4）は EX1 でオペランドとシフト量を登録し、EX2 で比較・分類と変換の前半、
    EX3 で後半、EX4 で書く（FCVT_PIPE、FCVT_PIPE2）。FCVT.S.D は EX2 で非正規化のシフト（fp_round_den）、EX3 はシフトなしの丸め。
    FCVT.D.S は丸め不要・非正規化数にならないので正規化済みの仮数をそのまま詰める。アンパック済みの仮数は正規化済みなので
    LZC は通さない（FCVT_DEN）。I2F は EX1 正規化、EX2 丸め（I2F_PIPE）
  - ALU パイプの wbpipe はレイテンシ 1 の値（ALU・CSR・リンク）を別入力で受ける（MUL / I2F の EX1 の論理を forward 経路に入れない）

### メモリ
- ロード: `IS | RR | AGU | MEM`（SQ・ストアバッファからのフォワード + dmem 読み）。load-to-use 3 サイクル（LD_SPEC_WAKE）。
  - LD_SPEC_WAKE: ロードは AGU で投機的に wakeup する（データの 1 サイクル前）。MEM で完了しない（リプレイキュー行き・RAW キュー満杯・
    MMIO。どれも AGU で分かり登録される）ときは翌サイクルに取り消す（SPEC_WAKE の取り消しポートを N_LDU 本増やす: N_CAN）。
    wakeup の直後のサイクルに発行した消費者は WB 段のレジスタ（bypass）から値を取り、読み出しポートを要求しない（発行キューの
    「ロードに起こされた」ビットは 1 サイクルだけ fresh。固定レイテンシの 2 サイクルとは別）。それ以降は PRF から読む。
    MEM で初めて分かる転送失敗は従来どおり flush で消費者ごと消える。LD_SPEC_WAKE=0 で旧サイクル数と完全に一致
  dmem は AGU のアドレス（dm_raddr_n）で同期読み出し、MEM で受け取る
- ストア: STA と STD を別 IQ・別パイプに分離（STD_SPLIT）。ストアは STA IQ k と対の STD IQ k に同じスロットで同時に入る
  （ディスパッチの空きは両方の小さい方）。STA: `IS | RR | AGU | SC`（AGU: アドレス・SQ 書込、SC: メモリ順序違反検査 + ROB 完了、
  ST_CHECK_STAGE）。STD: `IS | RR | EX`（SQ にデータを書く）。ROB 完了は両方が済んだとき（順序は任意）。
  読み出しポートは STA がベース、STD がデータ側（irp_slot）
- SQ フォワードは SQ ポインタのフラグからマスクを作り、バイトごとに最も若い一致ストアを優先エンコーダで選ぶ。
  転送失敗は「より古く、アドレスが一致してロードのバイトと重なり、データ未着のストアが 1 本でもある」のリダクション OR
  （FWD_FAIL_ANY。最若の選択はデータと StoreSet 学習用のストア PC にだけ使う）。最若でないストアの未着で失敗にしても
  サイクル数は全モードで同一だった
- メモリ順序違反: ストアより若いロードはストアの lq_ptr から末尾までの LQ エントリとしてポインタのマスクで求め（VIOL_LQMASK）、
  最古の違反ロードは one-hot（対数段の前置 OR）+ AND-OR で取り出す。アドレス比較は STA の AGU 段で行って登録し、AGU と同じ
  サイクルに MEM にいたロードは MEM 段のアドレスと比較して加える（VIOL_CAM_AGU）。再適用中の redirect による kill は選んだ
  最古のロードだけで判定（VIOL_KILL_LATE）。違反の redirect は 1 段レジスタに入れてから redirect 選択へ（VIOL_REG）。
  ストアの ROB 完了も同じだけ遅らせる（違反ロードが flush 前にコミットしないように）
- RAW キュー（RAWQ）: 違反検査の比較対象を LQ 全体ではなく RAW_N エントリのキューにする。ロードは AGU 段で「より古いストアに
  アドレス未確定のものがある」（アドレス確定ポインタ raw_ardy = SQ 先頭から最初のアドレス未確定エントリ、登録値）なら MEM で
  エントリを取りアドレス・マスク・LQ / SQ / ROB 番号を入れる（1 サイクル N_LDU 本、空きの下位から）。エントリは raw_ardy が
  ロードの SQ 位置を越えたらか flush で消える。違反検査は RAW の各エントリと MEM で今入るロードを比較して登録し、SC で LQ 番号に
  散らして従来の LQ マスク・最古の選択へ。空きがサイクル開始時に 2 × N_LDU 未満（登録）ならそのロードは完了せずリプレイキューで
  「待つストアのアドレスが全部出る」まで待って再実行。ロード同士の順序（RAR）のキューはない（キャッシュなし・シングルコア・
  MMIO ロードは ROB 先頭で順に実行なので不要）。RAW_N = 5 のストレステストで満杯時の経路も全モード一致
- ロードのリプレイキュー（LD_REPLAY）: AGU 段で「より古く、アドレスが一致してデータ未着のストア」を SQ に問い合わせ、結果を
  登録して MEM へ（SQ の探索を wakeup 経路に入れない）。該当したロードは完了も wakeup もせず、ロードパイプごとの LRQ_N = 4 エントリの
  キューに uop・アドレス・待つストアのビットを入れる。ビットはストアのデータが入ると消え、全部消えたエントリが翌サイクルに RR へ
  再投入される（そのサイクルは LDU の IQ を発行させない）。LQ の実行済みビットは立てない。MEM で初めて分かった転送失敗と
  キュー満杯は flush（StoreSet を学習）
- コミット後のストアバッファ（SBUFFER）: コミット済みストアは SQ の先頭から 2 本/cycle で SB_N = 16 エントリのライン
  （16 B: データメモリの 2 バンクに 1 dword ずつ = 1 書込サイクル分）へ移り、同じラインのエントリに併合（同じサイクルの 2 本が
  同じ新しいラインなら 1 エントリ）、SQ のエントリはその時点で空く。書き出しは 1 ライン/cycle の 2 段: s0 で有効ビット付きの
  木 PLRU で犠牲を選んで登録、s1 でエントリから読んでメモリへ書きエントリを消す。契機は有効数 ≥ SB_THRESH = 9（登録）、
  2^20 サイクルのタイムアウト、MMIO のための排出。s0 で選ばれたラインもそのサイクルは併合を受け、s1 のラインは受けない。
  ロードは MEM でバッファからも転送（dmem < 書き出し中ライン < 他のエントリ < SQ の順に上書き）。MMIO ストアはバッファが
  空になってから SQ 先頭から直接書き、MMIO ロードも空を待つ。乱数テストの最終メモリはバッファの中身を重ねて出す（tb.sv）。
  CoreMark で 53%、string_mem で 76% のストアが併合される。SBUFFER=0 では SQ から直接 2/cycle で書く（2 本目は別バンクのときだけ）
  - SB_MATCH_PRE: SQ 先頭のストアとバッファのラインの一致を前のサイクルに求めて登録する。先頭は 1 サイクルに 0〜2 進むので、
    先頭から 4 本のタグをそれぞれ「次のサイクルにエントリが持つタグ」（このサイクルに書くエントリは書くライン、他は今のタグ）と
    比較し、進む数で 2 本分を選んで登録（同じラインかどうかも）。併合・割り当ては登録した一致ベクタから始まる。SQ を出るストアは
    コミット済みなのでアドレスは 2 サイクル以上前に書かれている。sim 専用で毎サイクル直接の比較と照合（選択をずらす変異で検出を確認）
- MMIO ロード（0x1000_0000..0x1fff_ffff）は投機実行しない: ROB 先頭かつ全コミット済みストアの書き出し後に 1 本ずつ実行
  （mm_core の unc_*）。2 本目は replay

## SoC とソフトウェア（rtl/mm_soc.sv, software/, sim/）
| アドレス | サイズ | |
|---|---|---|
| 0x0000_1000 | 4 KiB | 予約（Boot ROM / リセットベクタ用。未実装） |
| 0x1000_0000 | 4 KiB | UART（+0 TX, +4 STATUS, +8 RX） |
| 0x1000_1000 | 4 KiB | GPIO（+0 IN, +8 OUT） |
| 0x1000_2000 | 4 KiB | タイマ・実行状態（+0 MTIME, +8 INSTRET, +0x10 EXIT） |
| 0x8000_0000 | 64 KiB | 命令 SRAM（リセットベクタ。フェッチ専用） |
| 0x8001_0000 | 64 KiB | データ SRAM（.rodata/.data/.bss/heap/stack） |
- ツールチェーン: `$HOME/opt/riscv64/bin/riscv64-unknown-elf-gcc`（riscv-gnu-toolchain, GCC 15.1 + newlib、
  `--with-arch=rv64imfdc_zicsr --with-abi=lp64d --with-cmodel=medany`。8 GB RAM では `make -j4` まで）
- ハーバード構成: ロードは IMEM を読めないので .rodata もデータ SRAM に置く（link.ld）
- 乱数テスト用 tb/tb.sv はコアに従来の 2 KiB データメモリ（全アドレスでエイリアス）をつなぐ。SoC は sim/tb_soc.sv
- C テストはホスト（x86 gcc、`-funsigned-char -ffp-contract=off`）での実行結果をゴールデンとして UART 出力と比較。
  浮動小数点はビット列で出力し、FMA は fma() で明示（RISC-V gcc は既定で積和を縮約するため）
- RTL がずれたら `make -C sim check PROG=...` で ISS とロックステップ照合し、最初に食い違う命令を特定する
- CoreMark は sim では 2 反復の短時間実行のため本体が "Errors detected"（10 秒未満の警告）を出すが、
  crclist/crcmatrix/crcstate = 0xe714/0x1fd7/0x8e3a で正しい。シミュレーション速度は 8-wide 約 1k、MM_SMALL 約 6k cycles/s

## ビルドとテスト
```sh
tb/run.sh 100                       # 乱数プログラム 100 本（seed 1..100）
MODE=loop CYC=12000 tb/run.sh 100   # ループ/関数呼び出し/switch 中心のプログラム
tb/run.sh 50 301                    # seed 301 から 50 本
REBUILD=1 tb/run.sh 10              # RTL を変えたら必ず REBUILD=1（8-wide で約 20 分かかる）
VFLAGS=+define+MM_SMALL REBUILD=1 tb/run.sh 50   # 4-wide 構成
MODE=fp CYC=2000 tb/prun.sh 300     # F/D/M 乱数プログラム（並列実行）
MODE=fpcsr CYC=2500 tb/prun.sh 300  # fp + Zicsr（fflags/frm/fcsr/カウンタ、動的丸め）
MODE=rvc CYC=15000 tb/prun.sh 300   # RVC 中心のループ（静的に 53% が 16 bit 命令）
MODE=loop+c CYC=12000 tb/prun.sh 300   # 任意モード + c: RVC を混ぜて再配置
python3 tb/xcheck_unicorn.py 200 rvc   # ISS の RVC デコードを Unicorn と比較
MODE=fploop CYC=12000 tb/prun.sh 100   # FP ループ（IPC 用）
python3 tb/xcheck_fp_unicorn.py 200000 1   # fpmodel/M を Unicorn と命令単位で比較
REBUILD=1 tb/fpu/run.sh 100000 1      # FPU 単体テスト（fpu.sv を変えたら REBUILD=1）
make -C sim test CONFIG=small|full    # SoC の C テスト
make -C sim coremark CONFIG=small|full
make -C sim check PROG=../software/coremark CONFIG=small   # ISS とロックステップ照合
```
- 合否判定: ISS とレジスタ書き込みの**全コミットトレース**および最終レジスタ/メモリが一致すること
- `tb/stats.txt`: 分岐 redirect、違反リプレイ、IFU redirect、walk サイクル、s2/s3 上書き、転送失敗、ロードリプレイ、RAW キュー投入など
- **RTL 変更後の合格基準**: 7 モード（rand / loop / fp / fpcsr / rvc / loop+c / fploop）× 300 本（CYC=15000）が両構成で全一致、
  SoC の C テスト全合格、CoreMark の CRC 正常。性能目的の変更なら同じ seed・同じ MODE でサイクル数を変更前と比較して記録する
- 性能比較は同じ seed 範囲・同じ MODE で行う（プログラム生成器を変えたら旧数値とは比べない）
- 性能カウンタ: `+PERF=<file>`（sim/perf.svh）で内訳を出す

## 現在の基準値（2026-11-08、LD_SPEC_WAKE 後）
乱数回帰（seed 1..300、CYC=15000、cycles）:
| MODE | 8-wide | MM_SMALL |
|---|---|---|
| rand | 55,466 | 66,644 |
| loop | 281,138 | 304,287 |
| fp | 66,145 | 73,193 |
| fpcsr | 128,843 | 135,158 |
| rvc | 127,011 | 141,507 |
| loop+c | 283,442 | 303,658 |
| fploop | 189,997 | 239,412 |

SoC（GCC 15.1 -O2、cycles）:
| プログラム | 命令数 | 8-wide | MM_SMALL |
|---|---|---|---|
| tests/int_ops | 103,449 | 52,464 | 67,824 |
| tests/float_ops | 80,064 | 41,107 | 49,222 |
| tests/string_mem | 328,952 | 184,992 | 198,416 |
| tests/control | 333,867 | 124,086 | 171,829 |
| CoreMark（2 反復、計測区間） | 661,825 | 212,454（9.413 CoreMark/MHz） | 266,061（7.517） |

`synthfast`（MM_SMALL、Nexys Video XC7A200T、2026-11-08、BP_LINE_PRE 後）: 最悪経路 14.70 ns（redir_q → 発行キューの v）、
> 14.5 ns 31 本・> 14 ns 117 本（バックエンド）、フロントエンド 14.10 ns（学習キューへの投入）・> 14 ns 61 本、LUT 441,912（デバイスの 3.3 倍）、FF 126,489

### タイミング改善（2026-11-02、周波数を上げて CoreMark/MHz はほぼ維持）
synthfast（MM_SMALL）の経路数: > 15 ns 316 → 99、> 14.5 ns 1,134 → 425、> 14 ns 3,208 → 741、> 13.5 ns 7,790 → 1,754。
最悪経路は 15.73 → 15.69 ns（誤差の範囲）、BUSY_DLY で 15.02 ns。CoreMark/MHz は 8.483 → 8.465 / 6.717 → 6.708（−0.2% / −0.14%。MV_NOCHAIN の保守的な履歴による）。
スイッチ（mm_pkg.sv、すべて 1）:
- FW_PIPE: 前向き walk の ROB 読み出しを 1 段前に（次のバッチをレジスタに置く）
- REN_GROUP_ACC の受理を連鎖なしに: acc = pa && 全体の受理条件。グループ内バイパスとスナップショットの中身は ren_pa から
  （スナップショットの中身は受理と無関係に書き、有効ビットだけ受理で立てる）。sim で旧 acc と照合
- MV_NOCHAIN: ムーブ除去の連鎖（除去された mv のソースを同じグループの別の除去 mv が書く）を DE で防ぐ。直前 DEC_W−1 本の履歴で判定
  （mv を外すだけ）。add のムーブは lsrc2 = x0 にして、除去しないときも正しい値になるようにした
- IQ_KILL_LATE: 発行キューの選択から redirect の kill を外し、選んだ後に kill で発行を取り消す（年齢順なので最古だけ見ればよい）
- IQ_CAN_BIT: 投機 wakeup の取り消しをエントリごとのポート別ビット（cw）× cancel_v で判定（タグ比較なし、sim で照合）。
  投機 wakeup は kill 前の選択（iss_sv）から
- FWD_ONEHOT: SQ フォワードのバイトごとの最若一致を後置 OR の one-hot で選び、データを列のリダクション OR で取る
- LF_STPC_LATE: 転送失敗のストア PC を登録した FTQ 番号から redirect 候補を作るときに読む
- RAW_LQOH: RAW キューのエントリに LQ 番号の one-hot を持たせ、SC の散らしを比較なしに
- MMIO_WREG: MMIO ストアの書込を 1 段レジスタに入れてから出す
- FADD_RAW: FADD 路のオペランドをアンパック前の生の値から取る
- BP_S3_SEL: s3 の判定に使う BTB バンク・チェック・ITTAGE の選択を s2 で登録
- BUSY_DLY: busy table の更新（wakeup・投機 wakeup の取り消し）を 1 サイクル遅らせる。DP は busy に前サイクルの登録済み
  wakeup / 取り消し / リネームした宛先を重ねて読むので準備状態は直接更新と同じ（サイクル数は完全に同一。sim で直接更新の表と
  毎サイクル照合）。発行 → wakeup → busy の経路（15.6 ns）が消え最悪経路 15.69 → 15.02 ns、> 14.5 ns 425 → 115、
  > 14 ns 741 → 258、> 13.5 ns 1,754 → 1,243。LUT は +9.8k（登録した wakeup のデコーダを他と共有できなくなるため）
- I2F の丸めを fp_round_fin_lim（sticky を前段で縮約、オーバーフロー判定を単純化）に。FPU 単体テストでパイプライン版 I2F も照合
残っている経路（BUSY_DLY 後、約 14.8〜15.0 ns）: SQ アドレス → 転送失敗の redirect（lf_q.valid）、FMA EX2 の加算
（add_q）、IFU F2 → IBuffer の pred_taken。ほぼ横並びなので 1 本ずつ直しても 0.2 ns 程度

### 2026-11-05: synthfast（390a382: 11-04〜11-05 の経路対策と DIV_OVL まで、FDIV_OVL の前）
- バックエンド（rt_grp2.tcl）: 最悪 15.02 → 14.67 ns、> 14.5 ns 83 → 3、> 14 ns 226 → 27、> 13.5 ns 1,004 → 284。
  11-03 の対象経路（lf_q.valid、FMA add_q、add_lmq → std_dat、fw_b_end / fwalk、viol_q）はすべて上位から消えた。
  残る上位: FDIV の反復（m → est）14.67、発行キューの jv → r1 14.61、DIV の cnt → 発行キューの r1（DIV_OVL の acc2 → div_blk）14.14
- フロントエンド: 最悪 14.84 → 15.34 ns、> 14 ns 32 → 1,812。ほぼ全部が TAGE 学習の U1（学習索引の複製レジスタ p_0_in、
  ファンアウト 121 → t_u の組合せ読み出し → 「provider より長い表で u = 0 の最初のウェイ」の割り当て連鎖 → t_u の書込デコード、
  20 段）。frontend.sv のこの部分は変えていないので配置・複製の揺れだが、段数は本物（前回はレポートの下限 12.7 ns 未満）
- LUT 418,744 → 405,903、FF 127,215 → 126,405
- 結果は $WINDIR_WSL/fpga/res_all6

### 2026-11-08: TAGE の s1 索引の加算器を前に出す（BP_LINE_PRE）
- 狙い: res_all13 の最悪経路 bpu_pc → チャンクの行アドレスの加算（CARRY4 3 段）→ 索引のハッシュ → 分散 RAM の読み →
  タグ比較・方向 → s2_tk（15.13 ns、21 段）
- 結果（synthfast、MM_SMALL）: bpu_pc → s2_tk はレポートの上位から消えた（13 ns 未満）。フロントエンドの最悪は 14.10 ns
  （学習キューの件数 → 投入）。全体の最悪は redir_q → 発行キューの v 14.70 ns（変えていない部分、前回 14.24）。LUT +1.0k
- サイクル数は両構成の全モード・SoC・CoreMark で完全に同一。結果は $WINDIR_WSL/fpga/res_all14

### 2026-11-08: ロードの投機的 wakeup（LD_SPEC_WAKE、load-to-use 4 → 3）
- 狙い: MM_SMALL の CoreMark で ROB 満杯のリネーム停止が 27%、ROB 先頭がロード待ちのサイクルが 22k / 328k。ロードは MEM で wakeup
  していたので消費者の発行はロードの 4 サイクル後だった。完了しないことは AGU で（登録して MEM へ）分かっているので、AGU で起こして
  外れたら SPEC_WAKE と同じ取り消しで戻す
- 結果: CoreMark 8.640 → 9.413（+8.9%）/ 6.839 → 7.517（+9.9%）（8-wide / MM_SMALL）。SoC: string_mem −8.4% / −5.8%、
  control −0.7% / −0.6%、float_ops −0.3% / −0.4%、int_ops −0.2% / −0.03%。乱数回帰: rand −1.9% / −1.2%、loop −1.6% / −1.9%、
  loop+c −1.6% / −1.9%、fp −0.6% / −0.5%、fpcsr −0.5% / −0.5%、rvc −0.3% / −0.9%、fploop −0.9% / −0.9%。
  CoreMark は両構成で ISS とロックステップ照合（70.7 万命令）一致
- synthfast（MM_SMALL）: バックエンドは > 14 ns 319 → 29（取り消し・wakeup の追加で悪化した経路はない）。LUT +0.2k、FF +1.3k。
  フロントエンドの s1（TAGE の分散 RAM 読み → s2_tk）が 15.13 ns に出た（同じ RTL で前回 13.36 ns: 配置の揺れだが 21 段）
- 結果は $WINDIR_WSL/fpga/res_all13

### 2026-11-07: TAGE の容量 4 × 256 → 4 × 1024（タグ 8 → 10 bit）
- 狙い: CoreMark の分岐 redirect を減らす。MM_SMALL の CoreMark で表の容量とタグ幅を比較（CoreMark/MHz）:
  4 × 256 / 8 bit 6.705、4 × 1024 / 8 bit 6.835、4 × 1024 / 10 bit 6.839、4 × 4096 / 12 bit 6.866。
  8-wide: 8.470 → 8.640（4 × 1024 / 10 bit、+2.0%）、4 × 4096 / 12 bit 8.644（上積みなし）
- 結果（4 × 1024 / 10 bit）: CoreMark 6.705 → 6.839（+2.0%）/ 8.470 → 8.640（+2.0%）、分岐 redirect 3,303 → 2,794（MM_SMALL）。
  SoC: control 175,124 → 172,864 / 133,638 → 125,005（−6.5%）、string_mem −0.4%。乱数回帰は loop −0.4%、loop+c −0.4〜−0.5%、
  他は同一か ±0.01%
- 面積（synthfast、MM_SMALL）: LUT 416,273 → 521,121（+25%）、FF 127,360 → 179,640。フロントエンドだけで LUT 123,712 → 233,207。
  表（タグ・カウンタ）が RAM でなく FF + 読み出しの mux になっている（予測で表あたり 3 行、学習で 1 行を読む）。
  タイミングは悪化なし（フロントエンドの最悪 13.28 ns）
- TAGE_RAM（表を分散 RAM に）: LUT 521,121 → 440,732、FF 179,640 → 125,544（4 × 256 のときの 127,360 より少ない: 当時の表も FF だった）、
  フロントエンド LUT 233,207 → 147,382（分散 RAM 9.2k）。4 × 256 → 4 × 1024 の差は LUT +24k。最悪経路 14.90 → 14.35 ns。
  サイクル数は両構成の全モード・SoC・CoreMark で完全に同一。結果は res_all11（FF 版）/ res_all12（TAGE_RAM）
- 学習キュー（TRQ_N）16 → 32 / 64 は MM_SMALL の CoreMark +0.15% / +0.26%（commit_cfi_limit 12.5k → 8.2k サイクル）で入れなかった
- MM_SMALL の CoreMark の内訳（+PERF）: ROB 満杯でリネーム停止 88k / 328k サイクル（27%）、ROB 先頭の待ちは BJU 47k・LDU 22k・ALU 14k

### 2026-11-07: 発行キューの選択 → wakeup → ready（IQ_WK_FAST）
- 狙い: res_all9 の最悪経路 発行キューの jv → r1（14.61 ns、16 段: ENQ_DELAY の拾い出し → ready → 最古選択 → lat の取り出しと
  比較 → wakeup のタグ → 各エントリの比較 → r1 の更新 4 段）
- 結果（synthfast、MM_SMALL）: 発行キュー内のループの経路（→ r* / jd / cw* / a*）は > 14 ns 18 → 13、> 13.5 ns 84 → 13、
  > 13 ns 157 → 67。最悪は wbb → r2 14.34 ns（17 段。比較 → ポートの OR → r の更新の 4〜5 段は残った: ウェイクアップポートが多く
  OR が木になる）。発行キュー 1 個あたり LUT 約 +740（11,884 → 12,628）、全体 406,548 → 416,273
- 全体の最悪は DP グループ → フリーリストの head 15.22 ns・redir_q → rc_ref 15.00 ns・DP → RAT 14.43 ns に移った（どれも変えて
  いない部分。res_all9 ではフリーリストの head 13.64（de_qd から）、rc_ref 13.35、RAT はレポートの下限未満で、配置の揺れ。
  DP → フリーリストは DP グループの投入可否 → can_rename → 受理数 → head の加算の 18 段）
- これ以上ループを縮めるには、タグ比較をやめて依存行列（消費者のソースごとに生産者の IQ エントリを投入時に記録し、選択の
  one-hot との AND で wakeup）にするしかない。FDIV の反復（14.58）と並ぶので、単独では最悪経路を 0.03 ns しか下げない
- サイクル数は両構成の全モード・SoC・CoreMark で完全に同一。結果は $WINDIR_WSL/fpga/res_all10

### 2026-11-06: ストアバッファの併合判定の前計算（SB_MATCH_PRE）
- 狙い: res_all8 の最悪経路 SQ 先頭のアドレス読み出し → 16 エントリのタグ比較（60 bit）→ 併合 / 割り当て → sq_head →
  エントリの書込（15.22 ns、17 段、> 15 ns 904 本）
- 結果（synthfast、MM_SMALL）: バックエンドの最悪 15.22 → 14.61 ns、> 15 ns 904 → 0、> 14.5 ns 3,629 → 5、> 14 ns 5,972 → 49、
  > 13.5 ns 6,000（レポート上限）→ 171。ストアバッファの経路は上位から消えた。LUT 408,941 → 406,548。残る上位は発行キューの
  jv → r1 14.61、FDIV の反復 14.58、redir_q → 発行キューの v 14.14、DIV の acc2 → 発行キュー 14.03 ns
- サイクル数は両構成の全モード・SoC・CoreMark で完全に同一（動作は変えない）
- 結果は $WINDIR_WSL/fpga/res_all9

### 2026-11-06: TAGE 学習の有用度ビットと redirect 選択の kill（TRAIN_U_REG / REDIR_KILL_LATE）
- 狙い: 11-05 の synthfast でフロントエンドの最悪が TAGE 学習 U1（学習索引 → t_u の組合せ読み出し → 割り当て連鎖 → t_u の
  書込デコード、20 段、15.34 ns、> 14 ns 1,812 本）。TRAIN_U_REG の後の synthfast ではバックエンドに redir_q → redirect 選択 →
  redir_q（22 段、15.11 ns。候補ごとの kill → 年齢比較 → MMIO replay の取り込み連鎖）が出た（前回は 13.2 ns・16 段）
- TRAIN_U_REG のみ（FDIV_OVL 込み）: フロントエンド 15.34 → 13.94 ns、> 14 ns 1,812 → 9、> 13.5 ns 2,374 → 260
- + REDIR_KILL_LATE: フロントエンド > 13.5 ns 18 本。redir_q の経路は上位から消えた。バックエンドの上位は SQ 先頭のアドレス →
  ストアバッファのタグ比較 → 併合 / 割り当て → sq_head → エントリの書込（15.22 ns、17 段、> 15 ns 904 本）だが、この部分は
  変えておらず前々回 13.36 ns、前回 12.39 ns（配置の揺れ。段数は本物なので次の候補）。その次は発行キューの jv → r1 14.58、
  FDIV の反復 14.58、wbq → rc_ref 14.44、DIV の acc2 → 発行キュー 14.14 ns。LUT 405,903 → 408,941（FDIV_OVL 込み）、FF 127,297
- サイクル数（MM_SMALL / 8-wide）: TRAIN_U_REG で loop +62 / +186、loop+c +26 / +131、CoreMark 298,129 → 298,268（6.708 → 6.705）/
  236,254 → 236,121（8.465 → 8.470）。他のモードは同一（8-wide fploop +1）。REDIR_KILL_LATE は乱数回帰では同一（tb.sv に MMIO なし）、
  SoC の C テストは両方合わせて +14〜+82 cycles（MM_SMALL では REDIR_KILL_LATE で +23〜+81: UART の MMIO replay が 1 サイクル遅れる）。
  MM_SMALL の CoreMark の計測区間は REDIR_KILL_LATE で同一
- 結果は $WINDIR_WSL/fpga/res_all7（TRAIN_U_REG のみ）、res_all8（両方）

### 2026-11-05: FDIV / FSQRT の重ね合わせ（FDIV_OVL）
- 狙い: FDIV は 1 回 10〜17 サイクル（S: ITER 7、D: 14 + start・POST・FIN）で、次の FDIV は前の書込まで発行できなかった。
  POST / DEN / FIN の 2〜3 サイクルを次の反復と重ねる
- 結果（seed 1..300、cycles、MM_SMALL / 8-wide）: fp 75,794 → 73,549（−3.0%）/ 67,094 → 66,512（−0.9%）、
  fpcsr 137,024 → 135,778（−0.9%）/ 129,778 → 129,525（−0.2%）、fploop 271,545 → 241,494（−11.1%）/ 202,257 → 191,818（−5.2%）。
  他のモード・CoreMark は同一、SoC float_ops 49,458 → 49,377 / 41,236 → 41,232。FDIV_OVL=0 で旧サイクル数と完全に一致（MM_SMALL fp / fpcsr / fploop）
- FPU 単体テストに FDIV_OVL 版のインスタンスを追加: 全 FDIV / FSQRT ベクタを「受けられるサイクルに毎回 start」で連続投入し、
  順に結果を照合（10 万ベクタあたり約 8,700 演算）。FIN の符号を写しでなく反復部のレジスタから取る変異で 2,708 件不一致になることを確認
- 段の深さ・synthfast は未測定。acc2 は整数 DIV と同じく cnt の比較 → 発行キューの選択に入る（DIV では 14.14 ns だった）

### 2026-11-05: 整数除算器の段の統合と重ね合わせ（DIV_PRE1 / DIV_POST1 / DIV_OVL）
- 狙い: MM_SMALL の int_ops で ROB 先頭が DIV 待ちのサイクルが 14.8k / 79.8k（18.6%）。1 回あたり固定で約 8 サイクル
  （start・PRE0・PRE1・POST0・POST1・FIN と書込）かかり、次の DIV は前の結果が出るまで発行できなかった（独立な a / b, a % b でも直列）
- 結果（MM_SMALL の SoC、全体のサイクル数）: int_ops 79,761 → 74,126（PRE1 + POST1）→ 67,837（+ OVL、−15.0%）。
  DIV 待ち 14.8k → 4.0k。string_mem −0.3%、float_ops / control −0.2〜−0.1%。全スイッチ 0 で旧サイクル数と完全に一致
- 乱数回帰（seed 1..300）: rand / loop / loop+c は同一。fp −2.1% / −2.9%、fpcsr −2.0% / −2.2%、rvc −2.2% / −1.7%、
  fploop −1.1% / −2.7%（MM_SMALL / 8-wide）。CoreMark は両構成で同一（8.465 / 6.708）。8-wide の int_ops は 10-30 の値
  55,267 から 52,553（同じ測り方での変更前の値は取っていない）
- 段の深さは未測定（PRE は LZC → シフト 2 段、POST は 71 bit の加算 → 選択 → 右シフト。符号の反転は結果段に残した）

### 2026-11-05: IBuffer の pred_taken、スナップショット選択、FADD EX2（synthfast は未実施）
11-03 の synthfast（MM_SMALL）の経路を対象に。3 つともサイクル数は両構成の全モード・SoC・CoreMark で完全に同一
- IFU_PT_SLOT: IBuffer に書く pred_taken をスロットごとに自分のチェック結果（未予測 JAL、または故障なしの予測 taken スロット）
  から決める。旧式は「スロット = 渡す件数 − 1」で、故障の優先エンコーダ → 件数 → 比較が直列（f2_ptr → ibuf 14.84 ns）。
  渡すスロットでは同じ値（sim 専用で毎サイクル照合）
- SNAP_SEL_OH（上記）: redir_q → fw_b_end 14.76 / fwalk 14.56 / fw_ptr 14.21 ns が対象。redirect 位置の減算（rob_sub1）も外れる
- FADD_RSEL（上記）: ASAP7（abc_keep）で FADD EX2 34.7 → 25.9 FO4。新しい最悪は正確な経路の LZC → 指数。11-03 の経路
  add_lmq → std_dat 14.82 / f_ex_s* 14.27 ns（EX2 の結果 → RR の forward）が対象。FPU 単体テスト 10 万ベクタ × 5 seed 一致。
  2 bit 以上の相殺で丸めが要る値が出たら sim で $error。rx の LSB を反転する変異で単体テストが不一致になることも確認
  （ベクタがこの経路を通っている）
- 続き（同じ 11-03 の経路。4 つともサイクル数は両構成の全モード・SoC・CoreMark で完全に同一、FPU 単体テスト 10 万ベクタ × 2 seed 一致）:
  - WBP_FEX_NOL1: FEX の wbpipe にレイテンシ 1 の受け口を作らない（FEX にレイテンシ 1 の uop はない。来たら sim で $error）。
    発行 → wbpipe のレイテンシ 1 判定 → RR の forward（iq jv → r1 14.34 ns）が対象
  - VIOL_KILL_OH: 最古の違反ロードの kill を、選んだ後の ROB 番号比較ではなく LQ エントリごとの kill ビットを同じ one-hot で
    取り出して判定。登録した違反はもう一度 kill 判定しない（rcam_q → viol_q 14.30 ns）。sim 専用で kill されたロードの違反を検査
  - RC_TRK_NOKILL: 発行キューのレジスタキャッシュ追跡に kill 前の書込を使う（kill される書込の preg は生存エントリのソースでなく、
    kill されたエントリは発行しない）。redir_q → rc_ref 14.12 ns が対象。RC_TRACK の照合で確認
  - FP_LZC_TREE: FP のアンパック（非正規化数の正規化）と fp_round_norm の先頭 1 探索を木構造の mm_lzc に（ループは仮数幅の
    連鎖になる）。f_ex_s1 → FCVT p_sh 14.12 ns が対象

### 2026-11-04: 転送失敗の経路と FADD EX1（synthfast は未実施）
- FWD_FAIL_ANY: 転送失敗の判定から最若ストアの選択（バイトごとの one-hot）を外し、一致ベクタ & データ未着のリダクション OR に。
  lf_q.valid の kill 判定も外した（lf_s は生存ロードにだけ立ち、生存判定に kill が入っている）。両構成とも全モードでサイクル数同一
- FADD_RAWEXP: ASAP7 の段の深さ（asic/ の流れ、abc_keep）で FADD EX1 54.7 → 48.8 FO4。FPU 単体テスト 10 万ベクタ × 3 seed 一致
- 試して入れなかったもの: FADD の近接 / 遠隔の 2 経路（指数差 ≤ 1 の引き算を別路で）は EX1 が 54.7 → 58.8 FO4 に悪化。
  EX1 の中身は指数の引き算（約 17 FO4）+ 桁合わせシフト（約 20）+ 加算（約 21）で、2 経路にしてもどれも消えない。
  FMA の CSA を EX1 に寄せる・EX1 の CSA 段数を 6 / 7 にするのも効かなかった
- ASAP7 での FP の段（FO4、±4 程度の揺れ）: FMA EX1〜EX4 約 49〜53（EX2 は表示 61 のうち約 11 が未バッファの高ファンアウト
  レジスタの clk→Q）、FADD EX1 約 49。これ以上は段を増やす（FP レイテンシ +1〜2）しかない
- 割り算・変換器（高ファンアウトの FF 出力にバッファ木を入れて測定: asic/fanout_buf.py）: 未バッファでの「DIV 81 / FDIV 117 FO4」は
  状態 FF（ファンアウト 440）の clk→Q がほとんどだった。バッファ後は整数 DIV の反復 45、FDIV の丸め（FIN）66・反復 56、
  FCVT の EX3 67（同じ測り方で FMA の各段は 50〜57）。FIN / EX3 が深いのは丸めの前の非正規化の可変シフトで、FCVT の最悪は
  FCVT.D.S（非正規化数にならないのに汎用の丸めを通していた）
  - FDIV_DEN: 非正規化数になりうる結果だけ DEN 段を通す。FDIV の最悪は反復の 55.6（FIN は 52 以下）。サイクル数は非正規化数の
    結果のときだけ +1（乱数回帰 seed 1..300 で MM_SMALL fp +20 / fpcsr +25 / fploop +17、8-wide +8 / +21 / +42 cycles。
    他のモード・SoC・CoreMark は同一）
  - FCVT_DEN: FCVT の最悪 67 → 39 FO4（EX2 の q_d2s / q_mag 39、EX3 33）
  - FPU 単体テストに非正規化数付近の FDIV 商と FCVT.S.D のベクタを追加（10 万本あたりそれぞれ約 1,700 / 740 本が非正規化数の結果）

## 今後の候補（未決定。着手前に狙いと評価方法を決める）
- FPGA 実機評価: Alveo V80（約 260 万 LUT、HBM 32 GB）。2026-11-11 に MM_SMALL・100 MHz（WNS +0.133 ns）で
  C テストと CoreMark が実機で動いた（10000 回で 7.882 CoreMark/MHz、CRC 正常）。2026-11-12 に 8-wide も 57.69 MHz で動いた
  （9.976 CoreMark/MHz・IPC 3.301、flash の partition 1。LUT 159 万が 3 ダイに散り、経路の 86 % が配線遅延で 100 / 75 / 60 MHz は
  閉じなかった）。手順・レジスタマップは fpga/v80/README.md。8-wide の周波数を上げるなら SLR を意識したフロアプラン
- ベンチマーク: CoreMark の正規の実行規則（10 秒以上、-O3 などのフラグを揃える）、Embench-IoT（RV64 版）。予測器は ISS の分岐
  トレースでモデル評価（MPKI）してから RTL に入れる。SPEC は PCIe 経由のシステムコール転送と HBM の理想メモリ化が要る
- 分岐予測: 履歴を長くした表の追加、SC の再評価（TAGE の容量は 2026-11-07 に 4 × 1024 にした。4 × 4096 は上積みがほぼない）
- 残っている構造: 整数 PRF のバンク分割、FTQ ブロック単位の予測器学習、他の原因のロードリプレイ
- 命令融合は RV64GC の CoreMark で出現 0.03% のため見送り。Zicond は GCC が分岐を czero 化して命令・依存が増え CoreMark −1.4%（不採用）

## コーディング規約・既知の落とし穴
- 配列の書き込みは **エントリごとの generate + always_ff**（定数添字）で書く。1 つの巨大な always_ff に
  可変添字の書き込みを集めると Yosys が proc 段でメモリ不足になる（実際に起きた）
- 引数なしの function でモジュール信号を読むと Yosys が通らない → 組み合わせ信号にする
- Verilator: アンパック配列全体への NBA を for ループで書くと BLKLOOPINIT エラー → パック配列 or 定数展開
- `always_comb` 内で関数がモジュール配列を読む場合、sv2v は感度リストに配列を並べ Yosys が拒否する
  → 合成時は sv2v 出力の `always @(...)` を `always @(*)` に置換する
- always_comb の中で localparam を宣言しない・文の後に宣言を置かない（Verilator / Vivado で通らない）。
  always_ff の中でモジュールの信号にブロッキング代入しない（ローカル変数 + NBA にする）
- ポインタは {flag, index} の循環ポインタ。サイズは 2 のべき乗でなくてよい。加減算は必ず
  `rob_add / rob_sub1 / rob_dist / lq_add / lq_dist / sq_add / sq_dist` を使い、生の `+`/`-` を使わない
- kill 判定は `killed_by(redirect, rob_idx)`。redirect を適用するサイクルでは、全段の副作用
  （PRF 書込、ROB done、wakeup、redirect 生成、LQ/SQ 更新）をこの判定でゲートすること
- 新機能は mm_pkg.sv の `localparam bit` スイッチで ON/OFF できるようにし、比較できる状態を保つ
- 単精度値は NaN-boxing（上位 32 bit が全 1 でない S オペランドは正準 NaN）。FLW/FMV.W.X/S 結果は上位を 1 で埋める
- Unicorn 2.x（QEMU 5.0）は NaN-boxing、F v2.2 の FMIN/FMAX(sNaN)、FMA の ∞×0+qNaN での NV が未対応なので、
  FP のプログラム単位比較はできない（xcheck_fp_unicorn.py で命令単位に比較し、その 3 点は除外している）
- 生成器が不正エンコーディング（例: f3≠0 で f7=0x20）を出しても ISS は黙って実行してしまう。
  新しい生成パターンを足したら xcheck_unicorn.py で確認すること
- 予測器の索引を変えたら CoreMark（sim/ の make coremark）で必ず比較する。乱数テストの生成器は
  「次の命令への分岐」（skip=1）を多く出すので、分岐判定の変更で乱数テストだけ数 % 動くことがある
- SystemVerilog の落とし穴: `int'(N'(signed式))` は切り詰め後に符号拡張される（負になる）。
  配列添字・位置の計算は `(a - b + N) % N` か unsigned で書く（BTB/TAGE の位置計算で実際に起きた）
- 予測器や FTQ 側の構造を変えたら、sim 専用の自己検査（s2 参照比較、FTQ ターゲット比較）が $error を出さないことを確認する
- 生成器はアラインされたアクセスのみ出すこと（コアは非アラインのロード/ストア非対応）
- 構成を変えたら docs/block_diagram.svg と README の表も更新する
- Vivado（2024.1）が Verilator と違う意味に合成した書き方（V80 で実際に起きた。どちらも sim では検出できない）:
  - エントリごとの always_ff の書き込み条件に関数呼び出しの結果と genvar の比較（`if (pidx(padd(tail, n)) == e) q[e] <= ..`）
    → 全エントリで真になった（mm_freelist）。条件の中で算術を展開すると直る。関数で位置を always_comb に出しても直らない
  - `if (we) for (b) if (mask[b]) ram[a][8*b +: 8] <= ..` を複数の RAM の写しで共有 → 写し 0 の書き込みイネーブルが定数 0
    になった（mm_dmem、URAM / BRAM とも）。`we` をバイトイネーブルに畳み込む（`ewb = we ? mask : 0`）と直る
  - 合成時の不一致は fpga/v80/gl の流れ（合成後ネットリストの xsim + unisim）で RTL と同じサイクルの信号を比べて探す

## 合成・タイミング（FPGA / ASIC）
- Vivado 2024.2（Windows）を WSL から `fpga/run_vivado.sh <elab|synth|synthfast|impl|bit> <small|full> <imem words> <dmem words> <MHz> [prog dir]`
  で起動。比較は `synthfast`（-no_timing_driven、MM_SMALL で約 20 分）で行う。タイミング駆動の `synth` は 3 時間以上終わらない。
  経路の一覧は $WINDIR_WSL/fpga の rt_grp2.tcl（フロントエンド / バックエンド別の report_timing）で出す。
  同じ RTL でも経路が ±2 ns 動くので、1 回ずつの差は目安
- Windows 側のメモリが足りないと Vivado が "unable to allocate" で落ちる。`VIV_THREADS=2 WSLENV=VIV_THREADS fpga/run_vivado.sh ...`
- 経緯: MM_SMALL の LUT は 99 万 → 41 万、最悪経路は 351 ns → 15.7 ns（2026-10）。効いた対策の種類:
  - 直列の走査をやめる: フリーリストのビットマスク走査 → 循環キュー、SQ フォワード / 違反検査の整数距離比較 → ポインタのマスク +
    優先エンコーダ、発行キューの ROB 番号比較 → 年齢行列、ループ内の早期 return / アキュムレート → 一致ベクタ + リダクション OR
  - 重複の削減: 予測器をスロットごとに引く → ブロックごと（整列チャンク）、uop の PC / 64 bit ターゲット → FTQ から読む、
    命令メモリの独立ポート → ワードバンク、データメモリの非同期読み → 同期読み（BRAM）
  - 段の分割: Decode/Rename/Dispatch、IFU 3 段、WB 段、FMA 4 段、FCVT / I2F / MUL のパイプライン化、ストアの違反検査段、
    違反 redirect の登録、予測器学習の 2 段化、BPU の s1 での前計算
  - ループの短縮: 発行キューの選択 → wakeup → ready（ENQ_DELAY、IQ_ONEHOT、SPEC_WAKE、RC_TRACK）
- 合成の書き方の注意: `for (...) if (match) return 1;` や `u = u | (g[i] ? q[i] : 0)` のようなループは Vivado
  （-no_timing_driven）でポート数・エントリ数の直列連鎖になる。一致ベクタを作ってリダクション OR（`|m`）で書く。
  実行時の値による `%`（例: `ncls[f] % class_n(f)`）は一般の除算器になる（79.5 ns の経路が出た）。定数比較で折り返す
- ASIC 向けの段の深さ評価（asic/）: sv2v → Yosys 0.38 → ASAP7 RVT TT → OpenSTA（配置配線なし）。1 FO4 ≈ 19.5 ps（asic/fo4.v）。
  WSL のメモリ（約 7 GB）では mm_core / frontend 全体のマッピングは OOM。演算器単体（abc_keep / Booth）: 整数 DIV の反復 40 FO4、
  MUL 37、FDIV / FSQRT の反復 約 41、FMA の各段 66 以下、FADD 65。ABC の既定スクリプトは大きな加算器をリプル状に組み直すので
  段の比較には abc_keep を使い、LZC は木構造で書く（mm_lzc）。絶対値はマッピング品質に強く依存するので相対値で見る。
  FF は ABC の外なので FF 出力の高ファンアウトにはバッファが入らない（数百ファンアウトで clk→Q が 40 FO4 を超える）。段の深さは
  asic/fanout_buf.py でバッファ木を入れてから測る。FF 名を残すには synth の後に `rename -wire` を入れる
  ツール: ~/opt/src/OpenSTA/build/sta、~/opt/sv2v、yosys は skywater-pdk の conda 環境、ASAP7 は
  ~/MLCAD26-Contest-Scripts-Benchmarks/asap7（asic/merge_lib.py で 1 ファイルに統合）

## 過去の主な測定（詳細な経緯は 2026-11-09 に履歴を作り直す前の旧版の CLAUDE.md にある: ~/meimei-history-20261109.bundle）
- CoreMark/MHz の推移（8-wide / MM_SMALL）: 初期 7.252 / 5.794 → BJU 発行ポート・スナップショット・StoreSet などで 8.257 / 6.640 →
  段の分割（分岐ミスのペナルティ増）で 7.9 / 6.3 前後 → レジスタキャッシュ 7.940 / 6.362 → ムーブ除去 8.436 / 6.677 →
  STA/STD 分離・ロードリプレイ・ストアバッファ・RAW キュー 8.483 / 6.718 → タイミング対策 8.470 / 6.705 → TAGE 4 × 1024 8.640 / 6.839 → ロードの投機的 wakeup 9.413 / 7.517
- 大きく効いたもの: BJU を ALU と別の発行ポートに（最大の効果）、ロードの投機的 wakeup（CoreMark +9%）、RAS を s3 だけで更新（関数呼び出しの多い loop / rvc で −13〜−34%）、
  ムーブ除去（CoreMark +6%）、ロードのリプレイキュー（rand −26%）、演算器の SRT 化・パイプライン化（fp / fploop −10〜−17%）
- 効かなかったもの（8-wide CoreMark）: 予測器の学習キュー 16 → 64、uBTB 32 → 256（s2 上書き 19k → 15k、−0.1%）、SC（悪化）
- 整数 PRF の読み出しポート共有は rand +7% / control +5% の損失、レジスタキャッシュでその 83〜96% を取り戻した
  （ポートごとの単純な FIFO は 68〜78%、second chance で 87%、書込中のエントリへのヒットを加えて上の値）
- 分岐ミス判定を「予測 taken ^ taken」にした影響: CoreMark・C テストは不変、乱数テストは生成器の「次の命令への分岐」の分だけ遅い
- 予測器の索引（MM_SMALL、TAGE 4 × 128 時）: スロット単位 6.614、4B 整列 6.611、16B 整列 6.566、ブロック先頭 6.521。
  TAGE 256 エントリで 6.667、512 で 6.738
- in-order RV64I 5 段（別リポジトリ SynRV）との比較（4-wide 構成時）: ループ系で約 1.8 倍、周期分岐ループで約 3.1 倍

## ライセンスと出典
- `rtl/cpu_pkg.sv` `rtl/decoder.sv` `rtl/alu.sv` は eeic-vlsi/SynRV（https://github.com/eeic-vlsi/SynRV,
  Apache-2.0）の in-order コアを RV64I に拡張したもの。LICENSE と README の出典表記は残すこと
