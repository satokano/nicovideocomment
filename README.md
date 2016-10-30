ニコニコ生放送コメント収集ツール
==================================================

コメントを収集します。rmq_collector.rbで収集したものをメッセージキュー（Rabbit MQ）にキューイングし、あとは好きなように処理するという考えです。

マルチスレッド回りの動作のため、JRuby9000に特化する方針にしています。

[![Build Status](https://travis-ci.org/satokano/nicovideocomment.png)](https://travis-ci.org/satokano/nicovideocomment)
[![Code Climate](https://codeclimate.com/github/satokano/nicovideocomment.png)](https://codeclimate.com/github/satokano/nicovideocomment)
[![Test Coverage](https://codeclimate.com/github/satokano/nicovideocomment/badges/coverage.svg)](https://codeclimate.com/github/satokano/nicovideocomment)

インストール
------------

    git clone git@github.com:satokano/nicovideocomment.git
    bundle install --path vendor/bundle

設定
--------

- config.yaml.sampleをconfig.yamlにリネームして使用してください。内容は適宜編集してください。
- 大量にTCPコネクションを消費する書き方ですがこれをCelluloid::IOでなんとかして参りたい。ulimitのopen filesの値は数千～1万程度にしてもよいかも。


起動
--------

jruby, bundlerを使う場合で、以下の通り。（bundle環境下って「jruby」を2回書くしかないの？）RabbitMQは事前に起動しておく。

    jruby -S bundle exec jruby ./scraper.rb
    jruby -S bundle exec jruby ./rmq_collector.rb


できること
----------

- アラートサーバに接続して、枠の開始情報を受信し続けます。
- 枠の開始情報を受信すると、コメントサーバに接続し、枠終了までコメントを受信し続けます。
- コメント取得は複数の放送に対して同時並行で行います。
- でも多くしすぎると接続制限を食らうみたいなので、同時に取得する枠の数を設定できるようにしてあります。

未実装だけど今後やってみたいこと
--------------------------------
- Re:dashで可視化
- リスナーに対する分析／評価
 - リスナー評価（タグ付け？）
 - コテハン検知
 - 発言数の多いリスナー
 - 有名リスナー出現検知
 - 過去発言保存 （これもう生米さんがやってるなぁ）

- コメビュとの連携
 - リスナーに対する評価をコメビュに提供

- リコメンド （ある程度公式でやってるなぁ）

- Celluloid.io対応
 - http://celluloid.io/

動作確認環境
------------

手元では主にLinux（CentOS6）で動作確認しています。まれにFreeBSDを使っていることもあります。RubyはJRuby9000系しか使っていません。Travis CIでもjruby-9.0.x.xを指定して確認しています。Javaは8系を使っています。

- あとでRabbitMQとbunnyのバージョンを書く

License
-------
Copyright (c) 2011-2016 Satoshi OKANO. Distributed under the MIT License. See LICENSE.txt for further details.

2011/11/30

satokano@gmail.com
