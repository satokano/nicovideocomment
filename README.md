ニコニコ生放送コメント収集ツール
==================================================

片っ端からコメントを収集します。

インストール
------------

    git clone git@github.com:satokano/nicovideocomment.git
    bundle install --path vendor/bundle

設定
--------

- config.yaml.sampleをconfig.yamlにリネーム。内容は適宜編集すること。
- いまのところ、大量にTCPコネクションを消費する実装にしているので、ulimitのopen filesの値は数千～1万程度にしておくこと。


起動
--------

bundler対応、jemalloc対応を行ったので、以下の通り。

    bundler exec je ruby ./gather.rb


できること
----------

- アラートサーバに接続して、枠の開始情報を受信し続けます。
- 枠の開始情報を受信すると、コメントサーバに接続し、枠終了までコメントを受信し続けます。
- コメント取得は複数の放送に対して同時並行で行います。
- でも多くしすぎると接続制限を食らうみたいなので、同時に取得する枠の数を設定できるようにしてあります。

既知の問題
----------

- 数時間ぐらい動かしていると、メモリを食いすぎて遅くなる


未実装だけど今後やってみたいこと
--------------------------------
- リスナーに対する分析／評価
 - コテハン検知
 - 発言数の多いリスナー
 - 有名リスナー出現検知
 - 過去発言保存
 - リスナー評価（タグ付け？）
 - 凸者評価

- コメビュとの連携
 - リスナーに対する評価をコメビュに提供
 - リスナー評価の表示
 - 凸者評価の表示

- リコメンド
 - 有名リスナーがこの放送とこの放送を見ています
 - この放送を見ている人はこっちの放送も見ています

- Celluloid.io対応
 - http://celluloid.io/

動作確認環境
------------

主にLinux、ときどきFreeBSDで動作確認しています。GC.statを使っているためRuby 1.9.3が必要になります。

    [okano@localhost nvc]$ uname -a
    Linux localhost.localdomain 2.6.18-274.12.1.el5 #1 SMP Tue Nov 29 13:37:46 EST 2011 x86_64 x86_64 x86_64 GNU/Linux

    [okano@localhost nvc]$ cat /etc/redhat-release
    CentOS release 5.8 (Final)

    [okano@localhost nvc]$ ruby --version
    ruby 1.9.3p0 (2011-10-30 revision 33570) [x86_64-linux]


2011/11/30

satokano@gmail.com

