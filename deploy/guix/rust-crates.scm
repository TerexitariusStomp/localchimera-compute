(define-module (rust-crates)
  #:use-module (guix build-system cargo)
  #:export (lookup-cargo-inputs))

(define rust-addr2line-0.24.2
  (crate-source "addr2line" "0.24.2"
                "1hd1i57zxgz08j6h5qrhsnm2fi0bcqvsh389fw400xm3arz2ggnz"))

(define rust-adler2-2.0.0
  (crate-source "adler2" "2.0.0"
                "09r6drylvgy8vv8k20lnbvwq8gp09h7smfn6h1rxsy15pgh629si"))

(define rust-adler2-2.0.1
  (crate-source "adler2" "2.0.1"
                "1ymy18s9hs7ya1pjc9864l30wk8p2qfqdi7mhhcc5nfakxbij09j"))

(define rust-aead-0.5.2
  (crate-source "aead" "0.5.2"
                "1c32aviraqag7926xcb9sybdm36v5vh9gnxpn4pxdwjc50zl28ni"))

(define rust-aes-0.8.4
  (crate-source "aes" "0.8.4"
                "1853796anlwp4kqim0s6wm1srl4ib621nm0cl2h3c8klsjkgfsdi"))

(define rust-aes-0.9.3
  (crate-source "aes" "0.9.3"
                "0cpascsyy7mzjmx3q3q0fjz8aqyhcf0slj49dpfc6f4fwxngkw1m"))

(define rust-aes-gcm-0.10.3
  (crate-source "aes-gcm" "0.10.3"
                "1lgaqgg1gh9crg435509lqdhajg1m2vgma6f7fdj1qa2yyh10443"))

(define rust-ahash-0.8.12
  (crate-source "ahash" "0.8.12"
                "0xbsp9rlm5ki017c0w6ay8kjwinwm8knjncci95mii30rmwz25as"))

(define rust-aho-corasick-1.1.3
  (crate-source "aho-corasick" "1.1.3"
                "05mrpkvdgp5d20y2p989f187ry9diliijgwrs254fs9s1m1x6q4f"))

(define rust-aho-corasick-1.1.4
  (crate-source "aho-corasick" "1.1.4"
                "00a32wb2h07im3skkikc495jvncf62jl6s96vwc7bhi70h9imlyx"))

(define rust-aligned-0.4.3
  (crate-source "aligned" "0.4.3"
                "1186lhb3gb4x6spzw7ff0zcraa8cr9zqk4ldpm5g1vb2ijc0higf"))

(define rust-allocator-api2-0.2.18
  (crate-source "allocator-api2" "0.2.18"
                "0kr6lfnxvnj164j1x38g97qjlhb7akppqzvgfs0697140ixbav2w"))

(define rust-amplify-4.7.0
  (crate-source "amplify" "4.7.0"
                "0g9lpqsv02migphbdngprimy6fnzb1gxb4y7ss6rhhjq691bfivi"))

(define rust-amplify-4.9.0
  (crate-source "amplify" "4.9.0"
                "0c9v4whgyh08a6n8jv4bjnyab8hjc6dkjph1wyl587l8gjnb8zrz"))

(define rust-amplify-derive-4.0.1
  (crate-source "amplify_derive" "4.0.1"
                "0a6lwinr627v4j547xm0494vk0rm17xaidsrz6wkd6yqp3k0jqra"))

(define rust-amplify-num-0.5.3
  (crate-source "amplify_num" "0.5.3"
                "1bg9h12p9cm3vs80pngpzh6lc3wcjv1jy1276mrpy14255dbgg4r"))

(define rust-amplify-syn-2.0.1
  (crate-source "amplify_syn" "2.0.1"
                "0annky4dq5h5wg58pkbm0d3j07jndbgl9b2vic4q639w8y6zndkp"))

(define rust-android-system-properties-0.1.5
  (crate-source "android_system_properties" "0.1.5"
                "04b3wrz12837j7mdczqd95b732gw5q7q66cv4yn4646lvccp57l1"))

(define rust-android-tzdata-0.1.1
  (crate-source "android-tzdata" "0.1.1"
                "1w7ynjxrfs97xg3qlcdns4kgfpwcdv824g611fq32cag4cdr96g9"))

(define rust-anstream-1.0.0
  (crate-source "anstream" "1.0.0"
                "13d2bj0xfg012s4rmq44zc8zgy1q8k9yp7yhvfnarscnmwpj2jl2"))

(define rust-anstyle-1.0.14
  (crate-source "anstyle" "1.0.14"
                "0030szmgj51fxkic1hpakxxgappxzwm6m154a3gfml83lq63l2wl"))

(define rust-anstyle-parse-1.0.0
  (crate-source "anstyle-parse" "1.0.0"
                "03hkv2690s0crssbnmfkr76kw1k7ah2i6s5amdy9yca2n8w7zkjj"))

(define rust-anstyle-query-1.1.1
  (crate-source "anstyle-query" "1.1.1"
                "0aj22iy4pzk6mz745sfrm1ym14r0y892jhcrbs8nkj7nqx9gqdkd"))

(define rust-anstyle-query-1.1.5
  (crate-source "anstyle-query" "1.1.5"
                "1p6shfpnbghs6jsa0vnqd8bb8gd7pjd0jr7w0j8jikakzmr8zi20"))

(define rust-anstyle-wincon-3.0.11
  (crate-source "anstyle-wincon" "3.0.11"
                "0zblannm70sk3xny337mz7c6d8q8i24vhbqi42ld8v7q1wjnl7i9"))

(define rust-anyhow-1.0.102
  (crate-source "anyhow" "1.0.102"
                "0b447dra1v12z474c6z4jmicdmc5yxz5bakympdnij44ckw2s83z"))

(define rust-anyhow-1.0.89
  (crate-source "anyhow" "1.0.89"
                "1xh1vg89n56h6nqikcmgbpmkixjds33492klrp9m96xrbmhgizc6"))

(define rust-arraydeque-0.5.1
  (crate-source "arraydeque" "0.5.1"
                "0dn2xdfg3rkiqsh8a6achnmvf5nf11xk33xgjzpksliab4yjx43x"))

(define rust-arrayvec-0.7.6
  (crate-source "arrayvec" "0.7.6"
                "0l1fz4ccgv6pm609rif37sl5nv5k6lbzi7kkppgzqzh1vwix20kw"))

(define rust-as-slice-0.2.1
  (crate-source "as-slice" "0.2.1"
                "05j52y1ws8kir5zjxnl48ann0if79sb56p9nm76hvma01r7nnssi"))

(define rust-ascii-1.1.0
  (crate-source "ascii" "1.1.0"
                "05nyyp39x4wzc1959kv7ckwqpkdzjd9dw4slzyjh73qbhjcfqayr"))

(define rust-async-trait-0.1.83
  (crate-source "async-trait" "0.1.83"
                "1p8q8gm4fv2fdka8hwy2w3f8df7p5inixqi7rlmbnky3wmysw73j"))

(define rust-atom-syndication-0.12.7
  (crate-source "atom_syndication" "0.12.7"
                "18x4w5f9sf58f896a4cygbrfmkl09imimf85qxcdjkybw8iqvxnj"))

(define rust-atomic-waker-1.1.2
  (crate-source "atomic-waker" "1.1.2"
                "1h5av1lw56m0jf0fd3bchxq8a30xv0b4wv8s4zkp4s0i7mfvs18m"))

(define rust-autocfg-1.4.0
  (crate-source "autocfg" "1.4.0"
                "09lz3by90d2hphbq56znag9v87gfpd9gb8nr82hll8z6x2nhprdc"))

(define rust-autocfg-1.5.0
  (crate-source "autocfg" "1.5.0"
                "1s77f98id9l4af4alklmzq46f21c980v13z2r1pcxx6bqgw0d1n0"))

(define rust-axum-0.7.7
  (crate-source "axum" "0.7.7"
                "1bkhgnj7rk1aih1c1ylqkmn72mjbgi8lql1paim35j3s613kjkjh"))

(define rust-axum-auth-0.7.0
  (crate-source "axum-auth" "0.7.0"
                "02hjwhji03lrjsabkg22hnzk0paqvy0kbz7w2j3gcm2z30x12sc1"))

(define rust-axum-core-0.4.5
  (crate-source "axum-core" "0.4.5"
                "16b1496c4gm387q20hkv5ic3k5bd6xmnvk50kwsy6ymr8rhvvwh9"))

(define rust-axum-server-0.7.1
  (crate-source "axum-server" "0.7.1"
                "1n67cx39cm9zsm0dwm0nla67qjswj90ccqrwq0x3kagn904ckfjn"))

(define rust-backtrace-0.3.74
  (crate-source "backtrace" "0.3.74"
                "06pfif7nwx66qf2zaanc2fcq7m64i91ki9imw9xd3bnz5hrwp0ld"))

(define rust-base-x-0.2.11
  (crate-source "base-x" "0.2.11"
                "0w02sdqvg7zwm91agb2phikw4ri8jmncw32paxsv8ra1jv8ckfsc"))

(define rust-base16ct-0.2.0
  (crate-source "base16ct" "0.2.0"
                "1kylrjhdzk7qpknrvlphw8ywdnvvg39dizw9622w3wk5xba04zsc"))

(define rust-base256emoji-1.0.2
  (crate-source "base256emoji" "1.0.2"
                "0z07il99l7k6s5crhf28ka1j0pr7dsplkrkn474pfni4k86l7sdm"))

(define rust-base32-0.4.0
  (crate-source "base32" "0.4.0"
                "1ykwx8jhksqxghfgyw2pzikzjf4n9wqm1x2ww5wqyn68ssf6dki3"))

(define rust-base64-0.21.7
  (crate-source "base64" "0.21.7"
                "0rw52yvsk75kar9wgqfwgb414kvil1gn7mqkrhn9zf1537mpsacx"))

(define rust-base64-0.22.1
  (crate-source "base64" "0.22.1"
                "1imqzgh7bxcikp5vx3shqvw9j09g9ly0xr0jma0q66i52r7jbcvj"))

(define rust-base64ct-1.6.0
  (crate-source "base64ct" "1.6.0"
                "0nvdba4jb8aikv60az40x2w1y96sjdq8z3yp09rwzmkhiwv1lg4c"))

(define rust-base64ct-1.8.3
  (crate-source "base64ct" "1.8.3"
                "01nyyyx84bhwrcc168hn47d8gvz2pzpv3y3lmck7mq4hw5vh3x9a"))

(define rust-bcrypt-pbkdf-0.10.0
  (crate-source "bcrypt-pbkdf" "0.10.0"
                "18pjhsy3m2v0silsp4mjzz8i92zrpqxk9b059zrnk1w8zvhw5ska"))

(define rust-bitflags-1.3.2
  (crate-source "bitflags" "1.3.2"
                "12ki6w8gn1ldq7yz9y680llwk5gmrhrzszaa17g1sbrw2r2qvwxy"))

(define rust-bitflags-2.11.0
  (crate-source "bitflags" "2.11.0"
                "1bwjibwry5nfwsfm9kjg2dqx5n5nja9xymwbfl6svnn8jsz6ff44"))

(define rust-bitflags-2.6.0
  (crate-source "bitflags" "2.6.0"
                "1pkidwzn3hnxlsl8zizh0bncgbjnw7c41cx7bby26ncbzmiznj5h"))

(define rust-block-buffer-0.10.4
  (crate-source "block-buffer" "0.10.4"
                "0w9sa2ypmrsqqvc20nhwr75wbb5cjr4kkyhpjm1z1lv2kdicfy1h"))

(define rust-block-buffer-0.12.1
  (crate-source "block-buffer" "0.12.1"
                "1ak0cvmxz3yifqmzv6aba9606brsz7d5g3piv5xdcvjsx7dwgxnj"))

(define rust-block-padding-0.3.3
  (crate-source "block-padding" "0.3.3"
                "14wdad0r1qk5gmszxqd8cky6vx8qg7c153jv981mixzrpzmlz2d8"))

(define rust-block-padding-0.4.2
  (crate-source "block-padding" "0.4.2"
                "12q66364a5j80iqsi9jg8c447xp7inavmd1qlkw96kpg4b81s3vi"))

(define rust-blowfish-0.9.1
  (crate-source "blowfish" "0.9.1"
                "1mw7bvj3bg5w8vh9xw9xawqh7ixk2xwsxkj34ph96b9b1z6y44p4"))

(define rust-bstr-1.12.1
  (crate-source "bstr" "1.12.1"
                "1arc1v7h5l86vd6z76z3xykjzldqd5icldn7j9d3p7z6x0d4w133"))

(define rust-bumpalo-3.16.0
  (crate-source "bumpalo" "3.16.0"
                "0b015qb4knwanbdlp1x48pkb4pm57b8gidbhhhxr900q2wb6fabr"))

(define rust-bumpalo-3.20.2
  (crate-source "bumpalo" "3.20.2"
                "1jrgxlff76k9glam0akhwpil2fr1w32gbjdf5hpipc7ld2c7h82x"))

(define rust-byteorder-1.5.0
  (crate-source "byteorder" "1.5.0"
                "0jzncxyf404mwqdbspihyzpkndfgda450l0893pz5xj685cg5l0z"))

(define rust-bytes-1.11.1
  (crate-source "bytes" "1.11.1"
                "0czwlhbq8z29wq0ia87yass2mzy1y0jcasjb8ghriiybnwrqfx0y"))

(define rust-bytes-1.7.2
  (crate-source "bytes" "1.7.2"
                "1wzs7l57iwqmrszdpr2mmqf1b1hgvpxafc30imxhnry0zfl9m3a2"))

(define rust-bytesize-2.3.1
  (crate-source "bytesize" "2.3.1"
                "18vjp7wfik0xi54l3z2314s7zxjyywa4vvwhilawnas2nbkixnbb"))

(define rust-bzip2-0.5.2
  (crate-source "bzip2" "0.5.2"
                "0iya6nbj0p2y8jss0z05yncc5hadry164fw3zva01y06v4igpv29"))

(define rust-bzip2-0.6.1
  (crate-source "bzip2" "0.6.1"
                "0v1lgjxy944fdvsl97wmqs7f288crv7xddalk6y82jpk4jn3z9gk"))

(define rust-bzip2-sys-0.1.13+1.0.8
  ;; Unbundle the vendored bzip2 C source; link against system libbz2.
  (crate-source "bzip2-sys" "0.1.13+1.0.8"
                "056c39pgjh4272bdslv445f5ry64xvb0f7nph3z7860ln8rzynr2"
                #:snippet
                '(begin
                   (delete-file-recursively "bzip2-1.0.8")
                   (delete-file "build.rs")
                   (with-output-to-file "build.rs"
                     (lambda _
                       (format #t "fn main() {~@
                        println!(\"cargo:rustc-link-lib=bz2\");~@
                        }~%"))))))

(define rust-cbc-0.1.2
  (crate-source "cbc" "0.1.2"
                "19l9y9ccv1ffg6876hshd123f2f8v7zbkc4nkckqycxf8fajmd96"))

(define rust-cbc-0.2.1
  (crate-source "cbc" "0.2.1"
                "15l8zvdhfazl994ijjww6b8z0p4a7jrqhb44xc5ixlc8bzpcjbff"))

(define rust-cc-1.1.30
  (crate-source "cc" "1.1.30"
                "0icr3vn2r5scpgylbplffd5mh7jcdivqh9dfgsxymnc13fk06s5i"))

(define rust-cc-1.2.57
  (crate-source "cc" "1.2.57"
                "08q464b62d03zm7rgiixavkrh5lzfq18lwf884vgycj9735d23bs"))

(define rust-cc-1.2.60
  (crate-source "cc" "1.2.60"
                "084a8ziprdlyrj865f3303qr0b7aaggilkl18slncss6m4yp1ia3"))

(define rust-cfg-aliases-0.2.1
  (crate-source "cfg_aliases" "0.2.1"
                "092pxdc1dbgjb6qvh83gk56rkic2n2ybm4yvy76cgynmzi3zwfk1"))

(define rust-cfg-if-1.0.0
  (crate-source "cfg-if" "1.0.0"
                "1za0vb97n4brpzpv8lsbnzmq5r8f2b0cpqqr0sy8h5bn751xxwds"))

(define rust-cfg-if-1.0.4
  (crate-source "cfg-if" "1.0.4"
                "008q28ajc546z5p2hcwdnckmg0hia7rnx52fni04bwqkzyrghc4k"))

(define rust-chacha20-0.9.1
  (crate-source "chacha20" "0.9.1"
                "0678wipx6kghp71hpzhl2qvx80q7caz3vm8vsvd07b1fpms3yqf3"))

(define rust-chrono-0.4.38
  (crate-source "chrono" "0.4.38"
                "009l8vc5p8750vn02z30mblg4pv2qhkbfizhfwmzc6vpy5nr67x2"))

(define rust-chrono-0.4.44
  (crate-source "chrono" "0.4.44"
                "1c64mk9a235271j5g3v4zrzqqmd43vp9vki7vqfllpqf5rd0fwy6"))

(define rust-cipher-0.4.4
  (crate-source "cipher" "0.4.4"
                "1b9x9agg67xq5nq879z66ni4l08m6m3hqcshk37d4is4ysd3ngvp"))

(define rust-cipher-0.5.2
  (crate-source "cipher" "0.5.2"
                "0v7sic43nmz4rgql62wmxq0z63s80gnmd0w5q1vlhw6djcn2mkz8"))

(define rust-clap-4.6.0
  (crate-source "clap" "4.6.0"
                "0l8k0ja5rf4hpn2g98bqv5m6lkh2q6b6likjpmm6fjw3cxdsz4xi"))

(define rust-clap-builder-4.6.0
  (crate-source "clap_builder" "4.6.0"
                "17q6np22yxhh5y5v53y4l31ps3hlaz45mvz2n2nicr7n3c056jki"))

(define rust-clap-derive-4.6.0
  (crate-source "clap_derive" "4.6.0"
                "0snapc468s7n3avr33dky4y7rmb7ha3qsp9l0k5vh6jacf5bs40i"))

(define rust-clap-lex-1.1.0
  (crate-source "clap_lex" "1.1.0"
                "1ycqkpygnlqnndghhcxjb44lzl0nmgsia64x9581030yifxs7m68"))

(define rust-cmov-0.5.4
  (crate-source "cmov" "0.5.4"
                "0yh22sqdvcdrfbhvnja4kaq5dyklpb4s70w5r6rplfdw4jna17hc"))

(define rust-colorchoice-1.0.5
  (crate-source "colorchoice" "1.0.5"
                "0w75k89hw39p0mnnhlrwr23q50rza1yjki44qvh2mgrnj065a1qx"))

(define rust-concurrent-queue-2.5.0
  (crate-source "concurrent-queue" "2.5.0"
                "0wrr3mzq2ijdkxwndhf79k952cp4zkz35ray8hvsxl96xrx1k82c"))

(define rust-const-oid-0.9.6
  (crate-source "const-oid" "0.9.6"
                "1y0jnqaq7p2wvspnx7qj76m7hjcqpz73qzvr9l2p9n2s51vr6if2"))

(define rust-const-str-0.4.3
  (crate-source "const-str" "0.4.3"
                "1hz9f943vv7xh08ncw10b6aci8a5lwarip0xcvqpa929rdhi2hig"))

(define rust-core-foundation-sys-0.8.7
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "core-foundation-sys" "0.8.7"
                "12w8j73lazxmr1z0h98hf3z623kl8ms7g07jch7n4p8f9nwlhdkp"))

(define rust-cpubits-0.1.1
  (crate-source "cpubits" "0.1.1"
                "1bh6rvanxm00myf1rmnh44hq2jdxn69971c92s4klz0k76f5zf0m"))

(define rust-cpufeatures-0.2.14
  (crate-source "cpufeatures" "0.2.14"
                "1q3qd9qkw94vs7n5i0y3zz2cqgzcxvdgyb54ryngwmjhfbgrg1k0"))

(define rust-cpufeatures-0.2.17
  (crate-source "cpufeatures" "0.2.17"
                "10023dnnaghhdl70xcds12fsx2b966sxbxjq5sxs49mvxqw5ivar"))

(define rust-cpufeatures-0.3.1
  (crate-source "cpufeatures" "0.3.1"
                "0rkm1l35jy1z1yfg723fddsxc7vr0gc1hhfvc138hnqiwc58p8jw"))

(define rust-crc32fast-1.4.2
  (crate-source "crc32fast" "1.4.2"
                "1czp7vif73b8xslr3c9yxysmh9ws2r8824qda7j47ffs9pcnjxx9"))

(define rust-crc32fast-1.5.0
  (crate-source "crc32fast" "1.5.0"
                "04d51liy8rbssra92p0qnwjw8i9rm9c4m3bwy19wjamz1k4w30cl"))

(define rust-crossbeam-channel-0.5.13
  (crate-source "crossbeam-channel" "0.5.13"
                "1wkx45r34v7g3wyi3lg2wz536lrrrab4h4hh741shfhr8rlhsj1k"))

(define rust-crossbeam-channel-0.5.15
  (crate-source "crossbeam-channel" "0.5.15"
                "1cicd9ins0fkpfgvz9vhz3m9rpkh6n8d3437c3wnfsdkd3wgif42"))

(define rust-crossbeam-deque-0.8.6
  (crate-source "crossbeam-deque" "0.8.6"
                "0l9f1saqp1gn5qy0rxvkmz4m6n7fc0b3dbm6q1r5pmgpnyvi3lcx"))

(define rust-crossbeam-epoch-0.9.18
  (crate-source "crossbeam-epoch" "0.9.18"
                "03j2np8llwf376m3fxqx859mgp9f83hj1w34153c7a9c7i5ar0jv"))

(define rust-crossbeam-utils-0.8.20
  (crate-source "crossbeam-utils" "0.8.20"
                "100fksq5mm1n7zj242cclkw6yf7a4a8ix3lvpfkhxvdhbda9kv12"))

(define rust-crossbeam-utils-0.8.21
  (crate-source "crossbeam-utils" "0.8.21"
                "0a3aa2bmc8q35fb67432w16wvi54sfmb69rk9h5bhd18vw0c99fh"))

(define rust-crypto-bigint-0.5.5
  (crate-source "crypto-bigint" "0.5.5"
                "0xmbdff3g6ii5sbxjxc31xfkv9lrmyril4arh3dzckd4gjsjzj8d"))

(define rust-crypto-common-0.1.6
  (crate-source "crypto-common" "0.1.6"
                "1cvby95a6xg7kxdz5ln3rl9xh66nz66w46mm3g56ri1z5x815yqv"))

(define rust-crypto-common-0.1.7
  (crate-source "crypto-common" "0.1.7"
                "02nn2rhfy7kvdkdjl457q2z0mklcvj9h662xrq6dzhfialh2kj3q"))

(define rust-crypto-common-0.2.2
  (crate-source "crypto-common" "0.2.2"
                "0lql5wjlrjkd3r0w32rwbgqfmgg84ms3h65ldnlckmkc3nb4qvnf"))

(define rust-ct-codecs-1.1.2
  (crate-source "ct-codecs" "1.1.2"
                "1ld20516fr7ai0i89iwy8sb255lli1wyvxbyaln8sag6mk7ccsh2"))

(define rust-ct-codecs-1.1.6
  (crate-source "ct-codecs" "1.1.6"
                "1a1al3jf0vx3zmzg3s2x6kzq1l6ghkw153zkz5hhsh2y3afmh44v"))

(define rust-ctr-0.9.2
  (crate-source "ctr" "0.9.2"
                "0d88b73waamgpfjdml78icxz45d95q7vi2aqa604b0visqdfws83"))

(define rust-ctutils-0.4.2
  (crate-source "ctutils" "0.4.2"
                "17m2s9jv7i780k26cq2fcyslg0pakv9plwdrmygdwha1hfiiambx"))

(define rust-culpa-1.0.2
  (crate-source "culpa" "1.0.2"
                "1lqzzl88vs3h6ljpj6gi8wgkwyqm9gp6dmsnbbzv873v67lvzq2s"))

(define rust-culpa-macros-1.0.2
  (crate-source "culpa-macros" "1.0.2"
                "0ya207axxrjixibdnqfk0h9f96b2b1xmxdw9rwfwglv6f1qy2d0j"))

(define rust-curve25519-dalek-4.1.3
  (crate-source "curve25519-dalek" "4.1.3"
                "1gmjb9dsknrr8lypmhkyjd67p1arb8mbfamlwxm7vph38my8pywp"))

(define rust-curve25519-dalek-5.0.0
  (crate-source "curve25519-dalek" "5.0.0"
                "08xwlnprkq6ibqvd19kcjb4v95r4bs73kh66r0d1qbly10rx7vmm"))

(define rust-curve25519-dalek-derive-0.1.1
  (crate-source "curve25519-dalek-derive" "0.1.1"
                "1cry71xxrr0mcy5my3fb502cwfxy6822k4pm19cwrilrg7hq4s7l"))

(define rust-cvt-0.1.2
  (crate-source "cvt" "0.1.2"
                "1wdwg2rbjl86bcrymscl34pw31kyv1ada19jazpkjbdzgzvrpbnj"))

(define rust-cypheraddr-0.4.0
  (crate-source "cypheraddr" "0.4.0"
                "1n9hlw1jg3qn6gi6b4kpnjkw3aqjbnvp352ihc9r9faamp958p5s"))

(define rust-cyphergraphy-0.3.0
  (crate-source "cyphergraphy" "0.3.0"
                "1111vaq7adf68abf1nnch8vflh05fy7gv0xbgasxmp2xxz41cz5n"))

(define rust-cyphernet-0.5.2
  (crate-source "cyphernet" "0.5.2"
                "1qb25qyp6lz2h8rh8radxj6bw1y7d4984sf65j01syjai1lr755c"))

(define rust-darling-0.20.11
  (crate-source "darling" "0.20.11"
                "1vmlphlrlw4f50z16p4bc9p5qwdni1ba95qmxfrrmzs6dh8lczzw"))

(define rust-darling-core-0.20.11
  (crate-source "darling_core" "0.20.11"
                "0bj1af6xl4ablnqbgn827m43b8fiicgv180749f5cphqdmcvj00d"))

(define rust-darling-macro-0.20.11
  (crate-source "darling_macro" "0.20.11"
                "1bbfbc2px6sj1pqqq97bgqn6c8xdnb2fmz66f7f40nrqrcybjd7w"))

(define rust-data-encoding-2.10.0
  (crate-source "data-encoding" "2.10.0"
                "1shzipi8igi058fkx9wfiy6prd7d8rahz1lb7d4idw9nfvrf58fp"))

(define rust-data-encoding-2.6.0
  (crate-source "data-encoding" "2.6.0"
                "1qnn68n4vragxaxlkqcb1r28d3hhj43wch67lm4rpxlw89wnjmp8"))

(define rust-data-encoding-macro-0.1.15
  (crate-source "data-encoding-macro" "0.1.15"
                "0fg6abipcn5h8qa09r5ki5dv3vhq4qaxn1ipsvb7c8k2p9n9nmgi"))

(define rust-data-encoding-macro-0.1.19
  (crate-source "data-encoding-macro" "0.1.19"
                "1nsv6lb3qv7kbl82w7z903fjxgqqmqg2fjg66zb6355a2wyahhl1"))

(define rust-data-encoding-macro-internal-0.1.13
  (crate-source "data-encoding-macro-internal" "0.1.13"
                "0gyk580bjsjdy10n06f4gqh5kkqy296ndvcg21ychfzm1967ab9k"))

(define rust-data-encoding-macro-internal-0.1.17
  (crate-source "data-encoding-macro-internal" "0.1.17"
                "1pi0yxypbs01nqjnpcd0x4byvrrnzah9qhrdk63zd3kbzih71dks"))

(define rust-defer-heavy-0.1.0
  (crate-source "defer-heavy" "0.1.0"
                "1qd00mmhj43ic47mphdmjwc561jbxfvh6mdmrxwmj3kc7qg6jlsh"))

(define rust-der-0.7.10
  (crate-source "der" "0.7.10"
                "1jyxacyxdx6mxbkfw99jz59dzvcd9k17rq01a7xvn1dr6wl87hg7"))

(define rust-der-0.7.9
  (crate-source "der" "0.7.9"
                "1h4vzjfa1lczxdf8avfj9qlwh1qianqlxdy1g5rn762qnvkzhnzm"))

(define rust-deranged-0.3.11
  (crate-source "deranged" "0.3.11"
                "1d1ibqqnr5qdrpw8rclwrf1myn3wf0dygl04idf4j2s49ah6yaxl"))

(define rust-deranged-0.5.8
  (crate-source "deranged" "0.5.8"
                "0711df3w16vx80k55ivkwzwswziinj4dz05xci3rvmn15g615n3w"))

(define rust-derive-builder-0.20.2
  (crate-source "derive_builder" "0.20.2"
                "0is9z7v3kznziqsxa5jqji3ja6ay9wzravppzhcaczwbx84znzah"))

(define rust-derive-builder-core-0.20.2
  (crate-source "derive_builder_core" "0.20.2"
                "1s640r6q46c2iiz25sgvxw3lk6b6v5y8hwylng7kas2d09xwynrd"))

(define rust-derive-builder-macro-0.20.2
  (crate-source "derive_builder_macro" "0.20.2"
                "0g1zznpqrmvjlp2w7p0jzsjvpmw5rvdag0rfyypjhnadpzib0qxb"))

(define rust-descape-3.0.0
  (crate-source "descape" "3.0.0"
                "1cmz0ff4xj1d81z10c9cafgn9bkn38y42jp3hlm27d92zgcmf0vh"))

(define rust-deunicode-1.6.2
  (crate-source "deunicode" "1.6.2"
                "013biy7hhy59jcbry4dqn2pf4qhaw083ksn8xxiw373wjc37imdb"))

(define rust-diff-0.1.13
  (crate-source "diff" "0.1.13"
                "1j0nzjxci2zqx63hdcihkp0a4dkdmzxd7my4m7zk6cjyfy34j9an"))

(define rust-digest-0.10.7
  (crate-source "digest" "0.10.7"
                "14p2n6ih29x81akj097lvz7wi9b6b9hvls0lwrv7b6xwyy0s5ncy"))

(define rust-digest-0.11.3
  (crate-source "digest" "0.11.3"
                "1hnmhd4rkybr11292w42pz9ppzx1h49glrhqg107k4s1b2xnvpgi"))

(define rust-diligent-date-parser-0.1.5
  (crate-source "diligent-date-parser" "0.1.5"
                "1sc1llvmzgblnkzknc9ad4k5f4hjkj46fbrf3s91kx36jgbygvf8"))

(define rust-displaydoc-0.2.5
  (crate-source "displaydoc" "0.2.5"
                "1q0alair462j21iiqwrr21iabkfnb13d6x5w95lkdg21q2xrqdlp"))

(define rust-doc-comment-0.3.4
  (crate-source "doc-comment" "0.3.4"
                "1j8jbrw8335hciwn3h2idkfc3kmx3pfn0sxcwjw1m8lmn6w5a2bq"))

(define rust-dunce-1.0.5
  (crate-source "dunce" "1.0.5"
                "04y8wwv3vvcqaqmqzssi6k0ii9gs6fpz96j5w9nky2ccsl23axwj"))

(define rust-duration-str-0.21.0
  (crate-source "duration-str" "0.21.0"
                "0q9gy4iz63f6m0ysi88x2dx2w17fj0ypwg1kmjlp3730590d2z02"))

(define rust-dyn-clone-1.0.17
  (crate-source "dyn-clone" "1.0.17"
                "09cig7dgg6jnqa10p4233nd8wllbjf4ffsw7wj0m4lwa5w3z0vhd"))

(define rust-dyn-clone-1.0.20
  (crate-source "dyn-clone" "1.0.20"
                "0m956cxcg8v2n8kmz6xs5zl13k2fak3zkapzfzzp7pxih6hix26h"))

(define rust-ec25519-0.1.0
  (crate-source "ec25519" "0.1.0"
                "09f8f60n3m79hzylpqf26z5x46ky3yp15569733ph4f05wx57zdx"))

(define rust-ecdsa-0.16.9
  (crate-source "ecdsa" "0.16.9"
                "1jhb0bcbkaz4001sdmfyv8ajrv8a1cg7z7aa5myrd4jjbhmz69zf"))

(define rust-ed25519-1.5.3
  (crate-source "ed25519" "1.5.3"
                "1rzydm5wd8szkddx3g55w4vm86y1ika8qp8qwckada5vf1fg7kwi"))

(define rust-ed25519-2.2.3
  (crate-source "ed25519" "2.2.3"
                "0lydzdf26zbn82g7xfczcac9d7mzm3qgx934ijjrd5hjpjx32m8i"))

(define rust-ed25519-3.0.0
  (crate-source "ed25519" "3.0.0"
                "02lqd21jz8l6g8iwcf2zd8s205nqw8nphkdbhfghglbkdhpg7z19"))

(define rust-ed25519-dalek-2.2.0
  (crate-source "ed25519-dalek" "2.2.0"
                "1agcwij1z687hg26ngzwhnmpz29b2w56m8z1ap3pvrnfh709drvh"))

(define rust-ed25519-dalek-3.0.0
  (crate-source "ed25519-dalek" "3.0.0"
                "1pi598aab0y6j4bah68wf6rgmgqf0lfpfysszqxsp40jpyia3fkf"))

(define rust-either-1.15.0
  (crate-source "either" "1.15.0"
                "069p1fknsmzn9llaizh77kip0pqmcwpdsykv2x30xpjyija5gis8"))

(define rust-elliptic-curve-0.13.8
  (crate-source "elliptic-curve" "0.13.8"
                "0ixx4brgnzi61z29r3g1606nh2za88hzyz8c5r3p6ydzhqq09rmm"))

(define rust-encoding-rs-0.8.35
  (crate-source "encoding_rs" "0.8.35"
                "1wv64xdrr9v37rqqdjsyb8l8wzlcbab80ryxhrszvnj59wy0y0vm"))

(define rust-env-filter-1.0.1
  (crate-source "env_filter" "1.0.1"
                "1vvf9xhaxm0m78bp23b8j3cbv1vm5vffn3gaas27mc64rhm0rs9j"))

(define rust-env-logger-0.11.10
  (crate-source "env_logger" "0.11.10"
                "0smmk1hqzk7z91rg7fdq98d03gh9kidkd0ymim43zb4n457w0886"))

(define rust-equivalent-1.0.1
  (crate-source "equivalent" "1.0.1"
                "1malmx5f4lkfvqasz319lq6gb3ddg19yzf9s8cykfsgzdmyq0hsl"))

(define rust-equivalent-1.0.2
  (crate-source "equivalent" "1.0.2"
                "03swzqznragy8n0x31lqc78g2af054jwivp7lkrbrc0khz74lyl7"))

(define rust-erased-serde-0.4.10
  (crate-source "erased-serde" "0.4.10"
                "1v1dy16ff8mck2rfqdmwdxl14phlvr8rq0i7yqzxka6ngnhdibfj"))

(define rust-errno-0.3.14
  (crate-source "errno" "0.3.14"
                "1szgccmh8vgryqyadg8xd58mnwwicf39zmin3bsn63df2wbbgjir"))

(define rust-errno-0.3.9
  (crate-source "errno" "0.3.9"
                "1fi0m0493maq1jygcf1bya9cymz2pc1mqxj26bdv7yjd37v5qk2k"))

(define rust-fast-glob-0.3.3
  (crate-source "fast-glob" "0.3.3"
                "1akg873y2j7pxgdwa5n8qh6y2adgsn14am0jk45kji1czbpz9z1s"))

(define rust-fastrand-2.1.1
  (crate-source "fastrand" "2.1.1"
                "19nyzdq3ha4g173364y2wijmd6jlyms8qx40daqkxsnl458jmh78"))

(define rust-fastrand-2.3.0
  (crate-source "fastrand" "2.3.0"
                "1ghiahsw1jd68df895cy5h3gzwk30hndidn3b682zmshpgmrx41p"))

(define rust-ff-0.13.0
  (crate-source "ff" "0.13.0"
                "0jcl8yhcs5kbfxfpnrhpkkvnk7s666vly6sgawg3nri9nx215m6y"))

(define rust-ff-0.13.1
  (crate-source "ff" "0.13.1"
                "14v3bc6q24gbcjnxjfbq2dddgf4as2z2gd4mj35gjlrncpxhpdf0"))

(define rust-fiat-crypto-0.2.9
  (crate-source "fiat-crypto" "0.2.9"
                "07c1vknddv3ak7w89n85ik0g34nzzpms6yb845vrjnv9m4csbpi8"))

(define rust-fiat-crypto-0.3.0
  (crate-source "fiat-crypto" "0.3.0"
                "094z20x40qws7ca8khvjqssiajf5sy1b1cgdwqd0cl6kvlr1xkb4"))

(define rust-filetime-0.2.25
  (crate-source "filetime" "0.2.25"
                "11l5zr86n5sr6g6k6sqldswk0jzklm0q95rzikxcns0yk0p55h1m"))

(define rust-filetime-0.2.27
  (crate-source "filetime" "0.2.27"
                "1nspbkm1d1km7xfljcbl565swqxrihqyin8bqppig2gf3qal927r"))

(define rust-find-msvc-tools-0.1.9
  (crate-source "find-msvc-tools" "0.1.9"
                "10nmi0qdskq6l7zwxw5g56xny7hb624iki1c39d907qmfh3vrbjv"))

(define rust-flate2-1.0.34
  (crate-source "flate2" "1.0.34"
                "1w1nf2ap4q1sq1v6v951011wcvljk449ap7q7jnnjf8hvjs8kdd1"))

(define rust-flate2-1.1.9
  (crate-source "flate2" "1.1.9"
                "0g2pb7cxnzcbzrj8bw4v6gpqqp21aycmf6d84rzb6j748qkvlgw4"))

(define rust-fnv-1.0.7
  (crate-source "fnv" "1.0.7"
                "1hc2mcqha06aibcaza94vbi81j6pr9a1bbxrxjfhc91zin8yr7iz"))

(define rust-foldhash-0.1.3
  (crate-source "foldhash" "0.1.3"
                "18in1a8mjcg43pfrdkhwzr0w988zb2bmb6sqwi07snjlkhvcc7pq"))

(define rust-foldhash-0.1.5
  (crate-source "foldhash" "0.1.5"
                "1wisr1xlc2bj7hk4rgkcjkz3j2x4dhd1h9lwk7mj8p71qpdgbi6r"))

(define rust-form-urlencoded-1.2.1
  (crate-source "form_urlencoded" "1.2.1"
                "0milh8x7nl4f450s3ddhg57a3flcv6yq8hlkyk6fyr3mcb128dp1"))

(define rust-form-urlencoded-1.2.2
  (crate-source "form_urlencoded" "1.2.2"
                "1kqzb2qn608rxl3dws04zahcklpplkd5r1vpabwga5l50d2v4k6b"))

(define rust-fs-at-0.2.1
  (crate-source "fs_at" "0.2.1"
                "0dn0hi9inmppk3mypvnaimjcdrxr0f3pi8d2p8jxn9gajjb6rbql"))

(define rust-fs2-0.4.3
  (crate-source "fs2" "0.4.3"
                "04v2hwk7035c088f19mfl5b1lz84gnvv2hv6m935n0hmirszqr4m"))

(define rust-futures-channel-0.3.31
  (crate-source "futures-channel" "0.3.31"
                "040vpqpqlbk099razq8lyn74m0f161zd0rp36hciqrwcg2zibzrd"))

(define rust-futures-core-0.3.31
  (crate-source "futures-core" "0.3.31"
                "0gk6yrxgi5ihfanm2y431jadrll00n5ifhnpx090c2f2q1cr1wh5"))

(define rust-futures-core-0.3.32
  (crate-source "futures-core" "0.3.32"
                "07bbvwjbm5g2i330nyr1kcvjapkmdqzl4r6mqv75ivvjaa0m0d3y"))

(define rust-futures-sink-0.3.31
  (crate-source "futures-sink" "0.3.31"
                "1xyly6naq6aqm52d5rh236snm08kw8zadydwqz8bip70s6vzlxg5"))

(define rust-futures-sink-0.3.32
  (crate-source "futures-sink" "0.3.32"
                "14q8ml7hn5a6gyy9ri236j28kh0svqmrk4gcg0wh26rkazhm95y3"))

(define rust-futures-task-0.3.31
  (crate-source "futures-task" "0.3.31"
                "124rv4n90f5xwfsm9qw6y99755y021cmi5dhzh253s920z77s3zr"))

(define rust-futures-util-0.3.31
  (crate-source "futures-util" "0.3.31"
                "10aa1ar8bgkgbr4wzxlidkqkcxf77gffyj8j7768h831pcaq784z"))

(define rust-fxhash-0.2.1
  (crate-source "fxhash" "0.2.1"
                "037mb9ichariqi45xm6mz0b11pa92gj38ba0409z3iz239sns6y3"))

(define rust-generator-0.7.5
  (crate-source "generator" "0.7.5"
                "0knp7cllkf90l4wmfbhmb3c0ha9xn9afrzmphain1d12zy26bhaw"))

(define rust-generic-array-0.14.7
  (crate-source "generic-array" "0.14.7"
                "16lyyrzrljfq424c3n8kfwkqihlimmsg5nhshbbp48np3yjrqr45"))

(define rust-getopts-0.2.24
  (crate-source "getopts" "0.2.24"
                "1pylvsmq7fillnxmd6g58r7igdrlby412q37ws41z39va2ngpr6g"))

(define rust-getrandom-0.2.15
  (crate-source "getrandom" "0.2.15"
                "1mzlnrb3dgyd1fb84gvw10pyr8wdqdl4ry4sr64i1s8an66pqmn4"))

(define rust-getrandom-0.2.17
  (crate-source "getrandom" "0.2.17"
                "1l2ac6jfj9xhpjjgmcx6s1x89bbnw9x6j9258yy6xjkzpq0bqapz"))

(define rust-getrandom-0.3.4
  (crate-source "getrandom" "0.3.4"
                "1zbpvpicry9lrbjmkd4msgj3ihff1q92i334chk7pzf46xffz7c9"))

(define rust-getrandom-0.4.2
  (crate-source "getrandom" "0.4.2"
                "0mb5833hf9pvn9dhvxjgfg5dx0m77g8wavvjdpvpnkp9fil1xr8d"))

(define rust-ghash-0.5.1
  (crate-source "ghash" "0.5.1"
                "1wbg4vdgzwhkpkclz1g6bs4r5x984w5gnlsj4q5wnafb5hva9n7h"))

(define rust-gimli-0.31.1
  (crate-source "gimli" "0.31.1"
                "0gvqc0ramx8szv76jhfd4dms0zyamvlg4whhiz11j34hh3dqxqh7"))

(define rust-git-ref-format-0.3.1
  (crate-source "git-ref-format" "0.3.1"
                "18ax2jngmx58kh8rxdwm28rjq57ml0wvh6ghsq9sdaa9wpbf0a3l"))

(define rust-git-ref-format-0.6.0
  (crate-source "git-ref-format" "0.6.0"
                "1l4r8k1b6xf03pcr94mk98sa317absd7qmwkmcf277pfgjki6sgd"))

(define rust-git-ref-format-core-0.3.1
  (crate-source "git-ref-format-core" "0.3.1"
                "091l2h5k8janc5qsx7s9gnwmmci6flg7ivyknqnf7sam59kvkbmv"))

(define rust-git-ref-format-core-0.6.0
  (crate-source "git-ref-format-core" "0.6.0"
                "0r03il0s0chrj40247xpbjmmf0b1knaqzlilr0j6yn6xplxfym8r"))

(define rust-git-ref-format-macro-0.3.1
  (crate-source "git-ref-format-macro" "0.3.1"
                "193cwdi7bw38m1xiibsddma9j036li5p9zsd6bv03hnc78ssav1v"))

(define rust-git-ref-format-macro-0.6.0
  (crate-source "git-ref-format-macro" "0.6.0"
                "1xx519bbs6x53wxa6zg5dhaic9swmah3vf35aj7w4q99r04hywsf"))

(define rust-git2-0.19.0
  (crate-source "git2" "0.19.0"
                "091pv7866z1qjq800ys0wjv8n73wrv7fqdrddxcnq36w8lzbf0xr"))

(define rust-git2-0.20.4
  (crate-source "git2" "0.20.4"
                "0azykjpk3j6s354z23jkyq3r3pbmlw9ha1zsxkw5cnnpi1h2b23v"))

(define rust-globset-0.4.18
  (crate-source "globset" "0.4.18"
                "1qsp3wg0mgxzmshcgymdlpivqlc1bihm6133pl6dx2x4af8w3psj"))

(define rust-globwalk-0.9.1
  (crate-source "globwalk" "0.9.1"
                "0mz7bsa66p2rrgnz3l94ac4kbklh7mq8j30iizyxjy4qyvmn1xqb"))

(define rust-group-0.13.0
  (crate-source "group" "0.13.0"
                "0qqs2p5vqnv3zvq9mfjkmw3qlvgqb0c3cm6p33srkh7pc9sfzygh"))

(define rust-h2-0.4.6
  (crate-source "h2" "0.4.6"
                "01cjblya9zxyadvxcmgcv2bk9r9pyc8l8bbchjdg88clk738lkjj"))

(define rust-hashbrown-0.14.5
  (crate-source "hashbrown" "0.14.5"
                "1wa1vy1xs3mp11bn3z9dv0jricgr6a2j0zkf1g19yz3vw4il89z5"))

(define rust-hashbrown-0.15.0
  (crate-source "hashbrown" "0.15.0"
                "1yx4xq091s7i6mw6bn77k8cp4jrpcac149xr32rg8szqsj27y20y"))

(define rust-hashbrown-0.15.5
  (crate-source "hashbrown" "0.15.5"
                "189qaczmjxnikm9db748xyhiw04kpmhm9xj9k9hg0sgx7pjwyacj"))

(define rust-hashbrown-0.16.1
  (crate-source "hashbrown" "0.16.1"
                "004i3njw38ji3bzdp9z178ba9x3k0c1pgy8x69pj7yfppv4iq7c4"))

(define rust-hashlink-0.10.0
  (crate-source "hashlink" "0.10.0"
                "1h8lzvnl9qxi3zyagivzz2p1hp6shgddfmccyf6jv7s1cdicz0kk"))

(define rust-hashlink-0.9.1
  (crate-source "hashlink" "0.9.1"
                "1byq4nyrflm5s6wdx5qwp96l1qbp2d0nljvrr5yqrsfy51qzz93b"))

(define rust-heck-0.5.0
  (crate-source "heck" "0.5.0"
                "1sjmpsdl8czyh9ywl3qcsfsq9a307dg4ni2vnlwgnzzqhc4y0113"))

(define rust-hermit-abi-0.3.9
  (crate-source "hermit-abi" "0.3.9"
                "092hxjbjnq5fmz66grd9plxd0sh6ssg5fhgwwwqbrzgzkjwdycfj"))

(define rust-hermit-abi-0.5.2
  (crate-source "hermit-abi" "0.5.2"
                "1744vaqkczpwncfy960j2hxrbjl1q01csm84jpd9dajbdr2yy3zw"))

(define rust-hex-0.4.3
  (crate-source "hex" "0.4.3"
                "0w1a4davm1lgzpamwnba907aysmlrnygbqmfis2mqjx5m552a93z"))

(define rust-hmac-0.12.1
  (crate-source "hmac" "0.12.1"
                "0pmbr069sfg76z7wsssfk5ddcqd9ncp79fyz6zcm6yn115yc6jbc"))

(define rust-hmac-0.13.0
  (crate-source "hmac" "0.13.0"
                "0gw6avmix6ah63lf70dapxhml4dlcakl9f2lnm6b0hdf6abvq0v3"))

(define rust-html-escape-0.2.13
  (crate-source "html-escape" "0.2.13"
                "0xml3hswv0205fbm5iq7dqiwjkr6d245xkfppwi7wqjdfr4x86kd"))

(define rust-html-page-0.5.0
  (crate-source "html-page" "0.5.0"
                "08qp77wcdfdqrhq5jf4dy47v138ddd8d2v8995nvb3cd512ia63n"))

(define rust-http-1.1.0
  (crate-source "http" "1.1.0"
                "0n426lmcxas6h75c2cp25m933pswlrfjz10v91vc62vib2sdvf91"))

(define rust-http-body-1.0.1
  (crate-source "http-body" "1.0.1"
                "111ir5k2b9ihz5nr9cz7cwm7fnydca7dx4hc7vr16scfzghxrzhy"))

(define rust-http-body-util-0.1.2
  (crate-source "http-body-util" "0.1.2"
                "0kslwazg4400qnc2azkrgqqci0fppv12waicnsy5d8hncvbjjd3r"))

(define rust-httparse-1.9.5
  (crate-source "httparse" "1.9.5"
                "0ip9v8m9lvgvq1lznl31wvn0ch1v254na7lhid9p29yx9rbx6wbx"))

(define rust-httpdate-1.0.3
  (crate-source "httpdate" "1.0.3"
                "1aa9rd2sac0zhjqh24c9xvir96g188zldkx0hr6dnnlx5904cfyz"))

(define rust-humansize-2.1.3
  (crate-source "humansize" "2.1.3"
                "1msxd1akb3dydsa8qs461sds9krwnn31szvqgaq93p4x0ad1rdbc"))

(define rust-hybrid-array-0.4.14
  (crate-source "hybrid-array" "0.4.14"
                "0srzagwa3b41ildy4x3d7ckng51dj7aprkchnaysfbqm5asi8wbh"))

(define rust-hyper-1.5.0
  (crate-source "hyper" "1.5.0"
                "16pspkgizcnsr1qcpqvm5l45nfwk7244q9av56cqqwm40slg1gxv"))

(define rust-hyper-util-0.1.9
  (crate-source "hyper-util" "0.1.9"
                "12yhradh0bpwa9jjyyq6shrrcx9fxbdkrq06xj7ccfhqkyq6waa1"))

(define rust-iana-time-zone-0.1.61
  (crate-source "iana-time-zone" "0.1.61"
                "085jjsls330yj1fnwykfzmb2f10zp6l7w4fhq81ng81574ghhpi3"))

(define rust-iana-time-zone-haiku-0.1.2
  (crate-source "iana-time-zone-haiku" "0.1.2"
                "17r6jmj31chn7xs9698r122mapq85mfnv98bb4pg6spm0si2f67k"))

(define rust-icu-collections-2.1.1
  (crate-source "icu_collections" "2.1.1"
                "0hsblchsdl64q21qwrs4hvc2672jrf466zivbj1bwyv606bn8ssc"))

(define rust-icu-locale-core-2.1.1
  (crate-source "icu_locale_core" "2.1.1"
                "1djvdc2f5ylmp1ymzv4gcnmq1s4hqfim9nxlcm173lsd01hpifpd"))

(define rust-icu-normalizer-2.1.1
  (crate-source "icu_normalizer" "2.1.1"
                "16dmn5596la2qm0r3vih0bzjfi0vx9a20yqjha6r1y3vnql8hv2z"))

(define rust-icu-normalizer-data-2.1.1
  (crate-source "icu_normalizer_data" "2.1.1"
                "02jnzizg6q75m41l6c13xc7nkc5q8yr1b728dcgfhpzw076wrvbs"))

(define rust-icu-properties-2.1.2
  (crate-source "icu_properties" "2.1.2"
                "1v3lbmhhi7i6jgw51ikjb1p50qh5rb67grlkdnkc63l7zq1gq2q2"))

(define rust-icu-properties-data-2.1.2
  (crate-source "icu_properties_data" "2.1.2"
                "1bvpkh939rgzrjfdb7hz47v4wijngk0snmcgrnpwc9fpz162jv31"))

(define rust-icu-provider-2.1.1
  (crate-source "icu_provider" "2.1.1"
                "0576b7dizgyhpfa74kacv86y4g1p7v5ffd6c56kf1q82rvq2r5l5"))

(define rust-id-arena-2.3.0
  (crate-source "id-arena" "2.3.0"
                "0m6rs0jcaj4mg33gkv98d71w3hridghp5c4yr928hplpkgbnfc1x"))

(define rust-ident-case-1.0.1
  (crate-source "ident_case" "1.0.1"
                "0fac21q6pwns8gh1hz3nbq15j8fi441ncl6w4vlnd1cmc55kiq5r"))

(define rust-idna-0.5.0
  (crate-source "idna" "0.5.0"
                "1xhjrcjqq0l5bpzvdgylvpkgk94panxgsirzhjnnqfdgc4a9nkb3"))

(define rust-idna-1.1.0
  (crate-source "idna" "1.1.0"
                "1pp4n7hppm480zcx411dsv9wfibai00wbpgnjj4qj0xa7kr7a21v"))

(define rust-idna-adapter-1.2.1
  (crate-source "idna_adapter" "1.2.1"
                "0i0339pxig6mv786nkqcxnwqa87v4m94b2653f6k3aj0jmhfkjis"))

(define rust-ignore-0.4.25
  (crate-source "ignore" "0.4.25"
                "0jlv2s4fxqj9fsz6y015j5vbz6i475hj80j9q3sy05d0cniq5myk"))

(define rust-indexmap-2.13.0
  (crate-source "indexmap" "2.13.0"
                "05qh5c4h2hrnyypphxpwflk45syqbzvqsvvyxg43mp576w2ff53p"))

(define rust-indexmap-2.6.0
  (crate-source "indexmap" "2.6.0"
                "1nmrwn8lbs19gkvhxaawffzbvrpyrb5y3drcrr645x957kz0fybh"))

(define rust-inout-0.1.3
  (crate-source "inout" "0.1.3"
                "1xf9gf09nc7y1a261xlfqsf66yn6mb81ahlzzyyd1934sr9hbhd0"))

(define rust-inout-0.1.4
  (crate-source "inout" "0.1.4"
                "008xfl1jn9rxsq19phnhbimccf4p64880jmnpg59wqi07kk117w7"))

(define rust-inout-0.2.2
  (crate-source "inout" "0.2.2"
                "1iq39s01d3y56j2r6hf75yqhpa7s2ifwr316yzyi0879a9jcwl22"))

(define rust-inquire-0.7.5
  (crate-source "inquire" "0.7.5"
                "0an1bjs0yklk990d7ni65znmirs99p01wld221affw5g64qgkp8g"))

(define rust-is-terminal-polyfill-1.70.2
  (crate-source "is_terminal_polyfill" "1.70.2"
                "15anlc47sbz0jfs9q8fhwf0h3vs2w4imc030shdnq54sny5i7jx6"))

(define rust-itoa-1.0.11
  (crate-source "itoa" "1.0.11"
                "0nv9cqjwzr3q58qz84dcz63ggc54yhf1yqar1m858m1kfd4g3wa9"))

(define rust-itoa-1.0.18
  (crate-source "itoa" "1.0.18"
                "10jnd1vpfkb8kj38rlkn2a6k02afvj3qmw054dfpzagrpl6achlg"))

(define rust-jiff-0.2.23
  (crate-source "jiff" "0.2.23"
                "0nc37n7jvgrzxdkcgc2hsfdf70lfagigjalh4igjrm5njvf4cd8s"))

(define rust-jiff-static-0.2.23
  (crate-source "jiff-static" "0.2.23"
                "192ss3cnixvg79cpa76clwkhn4mmz10vnwsbf7yjw8i484s8p31a"))

(define rust-jobserver-0.1.32
  (crate-source "jobserver" "0.1.32"
                "1l2k50qmj84x9mn39ivjz76alqmx72jhm12rw33zx9xnpv5xpla8"))

(define rust-jobserver-0.1.34
  (crate-source "jobserver" "0.1.34"
                "0cwx0fllqzdycqn4d6nb277qx5qwnmjdxdl0lxkkwssx77j3vyws"))

(define rust-js-sys-0.3.72
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "js-sys" "0.3.72"
                "1a8r61hbgw5kmscgj3g5pzg2ywlnswvljy0l592v0xdxlayz323a"))

(define rust-js-sys-0.3.91
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "js-sys" "0.3.91"
                "171rzgq33wc1nxkgnvhlqqwwnrifs13mg3jjpjj5nf1z0yvib5xl"))

(define rust-keccak-0.1.5
  (crate-source "keccak" "0.1.5"
                "0m06swsyd58hvb1z17q6picdwywprf1yf1s6l491zi8r26dazhpc"))

(define rust-keccak-0.1.6
  (crate-source "keccak" "0.1.6"
                "0lynp77kk3xw5kbdnmpc4wzx3qqn9cyfvg5prfb3sfnfik4ww9nb"))

(define rust-lazy-static-1.5.0
  (crate-source "lazy_static" "1.5.0"
                "1zk6dqqni0193xg6iijh7i3i44sryglwgvx20spdvwk3r6sbrlmv"))

(define rust-leb128fmt-0.1.0
  (crate-source "leb128fmt" "0.1.0"
                "1chxm1484a0bly6anh6bd7a99sn355ymlagnwj3yajafnpldkv89"))

(define rust-lexopt-0.3.0
  (crate-source "lexopt" "0.3.0"
                "00dlvik2ygw8z101vf3bfndcvxhp92v25sbzz6bdiwvxgxhlpzxs"))

(define rust-libc-0.2.160
  (crate-source "libc" "0.2.160"
                "0kyf734dm5iplyq5p5jc4x5dqxjnc5jwawq9cngawx0qrl311cph"))

(define rust-libc-0.2.183
  (crate-source "libc" "0.2.183"
                "17c9gyia7rrzf9gsssvk3vq9ca2jp6rh32fsw6ciarpn5djlddmm"))

(define rust-libc-0.2.184
  (crate-source "libc" "0.2.184"
                "1bz4525m7lwzr63iidh7lp9ppz2c9va1pn6fyjh5wsp1ajjd5xa8"))

(define rust-libgit2-sys-0.17.0+1.8.1
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "libgit2-sys" "0.17.0+1.8.1"
                "093jxfl2i9vxdlgf7vk9d040sjwy0nq4fid640y7qix6m0k26iqh"))

(define rust-libgit2-sys-0.18.3+1.9.2
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "libgit2-sys" "0.18.3+1.9.2"
                "11rlbyihj3k35mnkxxz4yvsnlx33a4r9srl66c5vp08pp72arcy9"))

(define rust-libm-0.2.16
  (crate-source "libm" "0.2.16"
                "10brh0a3qjmbzkr5mf5xqi887nhs5y9layvnki89ykz9xb1wxlmn"))

(define rust-libm-0.2.8
  (crate-source "libm" "0.2.8"
                "0n4hk1rs8pzw8hdfmwn96c4568s93kfxqgcqswr7sajd2diaihjf"))

(define rust-libredox-0.0.2
  (crate-source "libredox" "0.0.2"
                "01v6pb09j7dl2gnbvzz6zmy2k4zyxjjzvl7wacwjjffqsxajry9s"))

(define rust-libredox-0.1.14
  (crate-source "libredox" "0.1.14"
                "02p3pxlqf54znf1jhiyyjs0i4caf8ckrd5l8ygs4i6ba3nfy6i0p"))

(define rust-libredox-0.1.3
  (crate-source "libredox" "0.1.3"
                "139602gzgs0k91zb7dvgj1qh4ynb8g1lbxsswdim18hcb6ykgzy0"))

(define rust-libz-sys-1.1.20
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "libz-sys" "1.1.20"
                "0wp4i6zl385ilmcqafv61jwsk1mpk6yb8gpws9nwza00x19n9lfj"))

(define rust-libz-sys-1.1.25
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "libz-sys" "1.1.25"
                "1hdg7nqfjaygcqidyknldsva4i4zvirbgqc7j06c72m6w8llqbym"))

(define rust-line-col-0.2.1
  (crate-source "line-col" "0.2.1"
                "1nvqjxn2kkxkph3qdlkc5xq1m2ygla4l0saga778sp2vp3vcsscy"))

(define rust-linux-raw-sys-0.12.1
  (crate-source "linux-raw-sys" "0.12.1"
                "0lwasljrqxjjfk9l2j8lyib1babh2qjlnhylqzl01nihw14nk9ij"))

(define rust-linux-raw-sys-0.4.14
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "linux-raw-sys" "0.4.14"
                "12gsjgbhhjwywpqcrizv80vrp7p7grsz5laqq773i33wphjsxcvq"))

(define rust-litemap-0.8.1
  (crate-source "litemap" "0.8.1"
                "0xsy8pfp9s802rsj1bq2ys2kbk1g36w5dr3gkfip7gphb5x60wv3"))

(define rust-localtime-1.3.1
  (crate-source "localtime" "1.3.1"
                "11vdz49sqqw8ydgg6vnc892z4vpym08vyx7v54r6xfmq1fg00sh1"))

(define rust-lock-api-0.4.14
  (crate-source "lock_api" "0.4.14"
                "0rg9mhx7vdpajfxvdjmgmlyrn20ligzqvn8ifmaz7dc79gkrjhr2"))

(define rust-log-0.4.22
  (crate-source "log" "0.4.22"
                "093vs0wkm1rgyykk7fjbqp2lwizbixac1w52gv109p5r4jh0p9x7"))

(define rust-log-0.4.29
  (crate-source "log" "0.4.29"
                "15q8j9c8g5zpkcw0hnd6cf2z7fxqnvsjh3rw5mv5q10r83i34l2y"))

(define rust-loom-0.5.6
  (crate-source "loom" "0.5.6"
                "1x9hmiv00ir79kypcg0jdw0j0fkd3ymq6rpv6pli6q5qifrfql7z"))

(define rust-lru-0.12.5
  (crate-source "lru" "0.12.5"
                "0f1a7cgqxbyhrmgaqqa11m3azwhcc36w0v5r4izgbhadl3sg8k13"))

(define rust-marked-yaml-0.7.2
  (crate-source "marked-yaml" "0.7.2"
                "13ddwcjd55ysa5ccw22zawy16p72abmdyx3ssrc40vqlmfkjbszj"))

(define rust-marked-yaml-0.8.0
  (crate-source "marked-yaml" "0.8.0"
                "1yhmx7j9gf6ywgr5x1zy0gpsaqgym87in5l3x7ycrzx8cr7cyxis"))

(define rust-match-lookup-0.1.2
  (crate-source "match-lookup" "0.1.2"
                "0wgpmgsqkxdb01kqi1vfk0gpl874b7a6yybnwvwvknwbkckywykm"))

(define rust-matchers-0.1.0
  (crate-source "matchers" "0.1.0"
                "0n2mbk7lg2vf962c8xwzdq96yrc9i0p8dbmm4wa1nnkcp1dhfqw2"))

(define rust-matchers-0.2.0
  (crate-source "matchers" "0.2.0"
                "1sasssspdj2vwcwmbq3ra18d3qniapkimfcbr47zmx6750m5llni"))

(define rust-matchit-0.7.3
  (crate-source "matchit" "0.7.3"
                "156bgdmmlv4crib31qhgg49nsjk88dxkdqp80ha2pk2rk6n6ax0f"))

(define rust-memchr-2.7.4
  (crate-source "memchr" "2.7.4"
                "18z32bhxrax0fnjikv475z7ii718hq457qwmaryixfxsl2qrmjkq"))

(define rust-memchr-2.8.0
  (crate-source "memchr" "2.8.0"
                "0y9zzxcqxvdqg6wyag7vc3h0blhdn7hkq164bxyx2vph8zs5ijpq"))

(define rust-memoffset-0.9.1
  (crate-source "memoffset" "0.9.1"
                "12i17wh9a9plx869g7j4whf62xw68k5zd4k0k5nh6ys5mszid028"))

(define rust-mime-0.3.17
  (crate-source "mime" "0.3.17"
                "16hkibgvb9klh0w0jk5crr5xv90l3wlf77ggymzjmvl1818vnxv8"))

(define rust-miniz-oxide-0.8.0
  (crate-source "miniz_oxide" "0.8.0"
                "1wadxkg6a6z4lr7kskapj5d8pxlx7cp1ifw4daqnkzqjxych5n72"))

(define rust-miniz-oxide-0.8.9
  (crate-source "miniz_oxide" "0.8.9"
                "05k3pdg8bjjzayq3rf0qhpirq9k37pxnasfn4arbs17phqn6m9qz"))

(define rust-mio-1.0.2
  (crate-source "mio" "1.0.2"
                "1v1cnnn44awxbcfm4zlavwgkvbyg7gp5zzjm8mqf1apkrwflvq40"))

(define rust-mio-1.2.0
  (crate-source "mio" "1.2.0"
                "1hanrh4fwsfkdqdaqfidz48zz1wdix23zwn3r2x78am0garfbdsh"))

(define rust-multibase-0.9.1
  (crate-source "multibase" "0.9.1"
                "014l697md16829k41hzmfx4in9jzhn774q5292bsq10z7kn3jdcv"))

(define rust-multibase-0.9.2
  (crate-source "multibase" "0.9.2"
                "0xzcj0ih8p0nzmajxbqwrav8alzwssqypnq6pgiv0lpl6m4bp546"))

(define rust-never-0.1.0
  (crate-source "never" "0.1.0"
                "149whplrasa92hdyg0bfcih2xy71d6ln6snxysrinq3pm1dblsn9"))

(define rust-newline-converter-0.3.0
  (crate-source "newline-converter" "0.3.0"
                "0zyw2hyjl89rj1zmp9n8fq69pbfp9zl1cbal73agxjxixjbv1dj7"))

(define rust-nix-0.29.0
  (crate-source "nix" "0.29.0"
                "0ikvn7s9r2lrfdm3mx1h7nbfjvcc6s9vxdzw7j5xfkd2qdnp9qki"))

(define rust-nonempty-0.11.0
  (crate-source "nonempty" "0.11.0"
                "07bljx1i4r4m5rkx1hx9jmd7sia4sbs6iv0v224jzbyck4dlg7jl"))

(define rust-nonempty-0.12.0
  (crate-source "nonempty" "0.12.0"
                "1dpc3xi8bd8dynkh42b0ysv8w4b5hvidmvcqdxrx0p1y6lkf0dwp"))

(define rust-nonempty-0.9.0
  (crate-source "nonempty" "0.9.0"
                "1rh8yv3l0531696d27x3fmv4ykbbi4xqwbmxs7ysr2d5l3ffypcr"))

(define rust-normpath-1.5.0
  (crate-source "normpath" "1.5.0"
                "16z68q809749ky2vl72f3lqnhf3vjclvcc3y2z5v8m2nj0msn8xz"))

(define rust-nu-ansi-term-0.46.0
  (crate-source "nu-ansi-term" "0.46.0"
                "115sywxh53p190lyw97alm14nc004qj5jm5lvdj608z84rbida3p"))

(define rust-nu-ansi-term-0.50.3
  (crate-source "nu-ansi-term" "0.50.3"
                "1ra088d885lbd21q1bxgpqdlk1zlndblmarn948jz2a40xsbjmvr"))

(define rust-num-bigint-dig-0.8.4
  (crate-source "num-bigint-dig" "0.8.4"
                "0lb12df24wgxxbspz4gw1sf1kdqwvpdcpwq4fdlwg4gj41c1k16w"))

(define rust-num-bigint-dig-0.8.6
  (crate-source "num-bigint-dig" "0.8.6"
                "1dxh3d8pzjc5k0kpy8gy2qhhhqs7zw8a7m564zl3ib8gcjkdsqg6"))

(define rust-num-conv-0.1.0
  (crate-source "num-conv" "0.1.0"
                "1ndiyg82q73783jq18isi71a7mjh56wxrk52rlvyx0mi5z9ibmai"))

(define rust-num-conv-0.2.0
  (crate-source "num-conv" "0.2.0"
                "0l4hj7lp8zbb9am4j3p7vlcv47y9bbazinvnxx9zjhiwkibyr5yg"))

(define rust-num-integer-0.1.46
  (crate-source "num-integer" "0.1.46"
                "13w5g54a9184cqlbsq80rnxw4jj4s0d8wv75jsq5r2lms8gncsbr"))

(define rust-num-iter-0.1.45
  (crate-source "num-iter" "0.1.45"
                "1gzm7vc5g9qsjjl3bqk9rz1h6raxhygbrcpbfl04swlh0i506a8l"))

(define rust-num-traits-0.2.19
  (crate-source "num-traits" "0.2.19"
                "0h984rhdkkqd4ny9cif7y2azl3xdfb7768hb9irhpsch4q3gq787"))

(define rust-numtoa-0.1.0
  (crate-source "numtoa" "0.1.0"
                "1vs9rhggqbql1p26x8nkha1j06wawwgb2jp5fs88b5gi7prvvy5q"))

(define rust-object-0.36.5
  (crate-source "object" "0.36.5"
                "0gk8lhbs229c68lapq6w6qmnm4jkj48hrcw5ilfyswy514nhmpxf"))

(define rust-once-cell-1.20.2
  (crate-source "once_cell" "1.20.2"
                "0xb7rw1aqr7pa4z3b00y7786gyf8awx2gca3md73afy76dzgwq8j"))

(define rust-once-cell-1.21.4
  (crate-source "once_cell" "1.21.4"
                "0l1v676wf71kjg2khch4dphwh1jp3291ffiymr2mvy1kxd5kwz4z"))

(define rust-once-cell-polyfill-1.70.2
  (crate-source "once_cell_polyfill" "1.70.2"
                "1zmla628f0sk3fhjdjqzgxhalr2xrfna958s632z65bjsfv8ljrq"))

(define rust-opaque-debug-0.3.1
  (crate-source "opaque-debug" "0.3.1"
                "10b3w0kydz5jf1ydyli5nv10gdfp97xh79bgz327d273bs46b3f0"))

(define rust-overload-0.1.1
  (crate-source "overload" "0.1.1"
                "0fdgbaqwknillagy1xq7xfgv60qdbk010diwl7s1p0qx7hb16n5i"))

(define rust-p256-0.13.2
  (crate-source "p256" "0.13.2"
                "0jyd3c3k239ybs59ixpnl7dqkmm072fr1js8kh7ldx58bzc3m1n9"))

(define rust-p384-0.13.0
  (crate-source "p384" "0.13.0"
                "02cjlxdvxwvhmnckqnydqpvrwhf5raj67q300d66m7y6pi8nyy3h"))

(define rust-p384-0.13.1
  (crate-source "p384" "0.13.1"
                "1dnnp133mbpp72mfss3fhm8wx3yp3p3abdhlix27v92j19kz2hpy"))

(define rust-p521-0.13.3
  (crate-source "p521" "0.13.3"
                "1cl5y2aypa1vxg181a0na3abndz1981pfdp2zkyml88z3wbf5j8g"))

(define rust-parking-lot-0.12.5
  (crate-source "parking_lot" "0.12.5"
                "06jsqh9aqmc94j2rlm8gpccilqm6bskbd67zf6ypfc0f4m9p91ck"))

(define rust-parking-lot-core-0.9.12
  (crate-source "parking_lot_core" "0.9.12"
                "1hb4rggy70fwa1w9nb0svbyflzdc69h047482v2z3sx2hmcnh896"))

(define rust-pbkdf2-0.12.2
  (crate-source "pbkdf2" "0.12.2"
                "1wms79jh4flpy1zi8xdp4h8ccxv4d85adc6zjagknvppc5vnmvgq"))

(define rust-pem-rfc7468-0.7.0
  (crate-source "pem-rfc7468" "0.7.0"
                "04l4852scl4zdva31c1z6jafbak0ni5pi0j38ml108zwzjdrrcw8"))

(define rust-percent-encoding-2.3.1
  (crate-source "percent-encoding" "2.3.1"
                "0gi8wgx0dcy8rnv1kywdv98lwcx67hz0a0zwpib5v2i08r88y573"))

(define rust-percent-encoding-2.3.2
  (crate-source "percent-encoding" "2.3.2"
                "083jv1ai930azvawz2khv7w73xh8mnylk7i578cifndjn5y64kwv"))

(define rust-pest-2.8.6
  (crate-source "pest" "2.8.6"
                "0qm6kpqsbn2p6vkd7v4j3g7wsjby2ip6di1h6kx7vlq921h8r170"))

(define rust-pest-derive-2.8.6
  (crate-source "pest_derive" "2.8.6"
                "0xzysvcyfs0pkn2801rg811y83jx2rvpqnjxs47c3ri1xbqqdx0i"))

(define rust-pest-generator-2.8.6
  (crate-source "pest_generator" "2.8.6"
                "0kzrcik2ww0qh84jlv8xqc0zmzgl3xy41vf1cfli1chkgdjc8h40"))

(define rust-pest-meta-2.8.6
  (crate-source "pest_meta" "2.8.6"
                "08126skq2lxysinp6v917niszhnnh6d6a9kg2i0a28b0sdlmr0c9"))

(define rust-pikchr-0.1.4
  (crate-source "pikchr" "0.1.4"
                "09hqsykj71b02yzjmy7nxc73ir8arkg56l7i4gc78286m4v06s0k"))

(define rust-pin-project-1.1.6
  (crate-source "pin-project" "1.1.6"
                "1v4924b870bss0x5ahww9a164d4dbny90vzkmljfbqfxc6hj7wds"))

(define rust-pin-project-internal-1.1.6
  (crate-source "pin-project-internal" "1.1.6"
                "1y2pjavbcq40njylbnw3929i8nnrcdzrhgalzgqk57ya2n2jsl54"))

(define rust-pin-project-lite-0.2.14
  (crate-source "pin-project-lite" "0.2.14"
                "00nx3f04agwjlsmd3mc5rx5haibj2v8q9b52b0kwn63wcv4nz9mx"))

(define rust-pin-project-lite-0.2.17
  (crate-source "pin-project-lite" "0.2.17"
                "1kfmwvs271si96zay4mm8887v5khw0c27jc9srw1a75ykvgj54x8"))

(define rust-pin-utils-0.1.0
  (crate-source "pin-utils" "0.1.0"
                "117ir7vslsl2z1a7qzhws4pd01cg2d3338c47swjyvqv2n60v1wb"))

(define rust-pkcs1-0.7.5
  (crate-source "pkcs1" "0.7.5"
                "0zz4mil3nchnxljdfs2k5ab1cjqn7kq5lqp62n9qfix01zqvkzy8"))

(define rust-pkcs8-0.10.2
  (crate-source "pkcs8" "0.10.2"
                "1dx7w21gvn07azszgqd3ryjhyphsrjrmq5mmz1fbxkj5g0vv4l7r"))

(define rust-pkg-config-0.3.31
  (crate-source "pkg-config" "0.3.31"
                "1wk6yp2phl91795ia0lwkr3wl4a9xkrympvhqq8cxk4d75hwhglm"))

(define rust-pkg-config-0.3.32
  (crate-source "pkg-config" "0.3.32"
                "0k4h3gnzs94sjb2ix6jyksacs52cf1fanpwsmlhjnwrdnp8dppby"))

(define rust-plain-0.2.3
  (crate-source "plain" "0.2.3"
                "19n1xbxb4wa7w891268bzf6cbwq4qvdb86bik1z129qb0xnnnndl"))

(define rust-polling-3.11.0
  (crate-source "polling" "3.11.0"
                "0622qfbxi3gb0ly2c99n3xawp878fkrd1sl83hjdhisx11cly3jx"))

(define rust-poly1305-0.8.0
  (crate-source "poly1305" "0.8.0"
                "1grs77skh7d8vi61ji44i8gpzs3r9x7vay50i6cg8baxfa8bsnc1"))

(define rust-polyval-0.6.2
  (crate-source "polyval" "0.6.2"
                "09gs56vm36ls6pyxgh06gw2875z2x77r8b2km8q28fql0q6yc7wx"))

(define rust-portable-atomic-1.13.1
  (crate-source "portable-atomic" "1.13.1"
                "0j8vlar3n5acyigq8q6f4wjx3k3s5yz0rlpqrv76j73gi5qr8fn3"))

(define rust-portable-atomic-util-0.2.6
  (crate-source "portable-atomic-util" "0.2.6"
                "18wrsx7fjwc2kgbpfjfm3igv3vdzsidmjhbqivjln7d0c6z9f4q9"))

(define rust-potential-utf-0.1.4
  (crate-source "potential_utf" "0.1.4"
                "0xxg0pkfpq299wvwln409z4fk80rbv55phh3f1jhjajy5x1ljfdp"))

(define rust-powerfmt-0.2.0
  (crate-source "powerfmt" "0.2.0"
                "14ckj2xdpkhv3h6l5sdmb9f1d57z8hbfpdldjc2vl5givq2y77j3"))

(define rust-ppv-lite86-0.2.20
  (crate-source "ppv-lite86" "0.2.20"
                "017ax9ssdnpww7nrl1hvqh2lzncpv04nnsibmnw9nxjnaqlpp5bp"))

(define rust-ppv-lite86-0.2.21
  (crate-source "ppv-lite86" "0.2.21"
                "1abxx6qz5qnd43br1dd9b2savpihzjza8gb4fbzdql1gxp2f7sl5"))

(define rust-pretty-assertions-1.4.1
  (crate-source "pretty_assertions" "1.4.1"
                "0v8iq35ca4rw3rza5is3wjxwsf88303ivys07anc5yviybi31q9s"))

(define rust-prettyplease-0.2.37
  (crate-source "prettyplease" "0.2.37"
                "0azn11i1kh0byabhsgab6kqs74zyrg69xkirzgqyhz6xmjnsi727"))

(define rust-primeorder-0.13.6
  (crate-source "primeorder" "0.13.6"
                "1rp16710mxksagcjnxqjjq9r9wf5vf72fs8wxffnvhb6i6hiqgim"))

(define rust-proc-macro-error-1.0.4
  (crate-source "proc-macro-error" "1.0.4"
                "1373bhxaf0pagd8zkyd03kkx6bchzf6g0dkwrwzsnal9z47lj9fs"))

(define rust-proc-macro-error-attr-1.0.4
  (crate-source "proc-macro-error-attr" "1.0.4"
                "0sgq6m5jfmasmwwy8x4mjygx5l7kp8s4j60bv25ckv2j1qc41gm1"))

(define rust-proc-macro-error-attr2-2.0.0
  (crate-source "proc-macro-error-attr2" "2.0.0"
                "1ifzi763l7swl258d8ar4wbpxj4c9c2im7zy89avm6xv6vgl5pln"))

(define rust-proc-macro-error2-2.0.1
  (crate-source "proc-macro-error2" "2.0.1"
                "00lq21vgh7mvyx51nwxwf822w2fpww1x0z8z0q47p8705g2hbv0i"))

(define rust-proc-macro2-1.0.106
  (crate-source "proc-macro2" "1.0.106"
                "0d09nczyaj67x4ihqr5p7gxbkz38gxhk4asc0k8q23g9n85hzl4g"))

(define rust-proc-macro2-1.0.88
  (crate-source "proc-macro2" "1.0.88"
                "1ygjzcawivbziakc6sfc816alabvnp6whlm3g6kxamqyvg2pyfkw"))

(define rust-pulldown-cmark-0.13.3
  (crate-source "pulldown-cmark" "0.13.3"
                "1bgxjn869lyyb8yc7cpj0pm1127kmrhh8hfby6b3g27sdn4i8fkw"))

(define rust-pulldown-cmark-escape-0.11.0
  (crate-source "pulldown-cmark-escape" "0.11.0"
                "1bp13akkz52p43vh2ffpgv604l3xd9b67b4iykizidnsbpdqlz80"))

(define rust-qcheck-1.0.0
  (crate-source "qcheck" "1.0.0"
                "1w7knnk2zhhczmymh6hdddsld4vlvmm6lpn930nxclfs891bsfdl"))

(define rust-qcheck-macros-1.0.0
  (crate-source "qcheck-macros" "1.0.0"
                "1ddiynmcs0i49gxx6vky3jnsg7nvyj1ikw8q9f81a1k9bapvjhi7"))

(define rust-quick-xml-0.37.5
  (crate-source "quick-xml" "0.37.5"
                "1yxpd7rc2qn6f4agfj47ps2z89vv7lvzxpzawqirix8bmyhrf7ik"))

(define rust-quote-1.0.37
  (crate-source "quote" "1.0.37"
                "1brklraw2g34bxy9y4q1nbrccn7bv36ylihv12c9vlcii55x7fdm"))

(define rust-quote-1.0.45
  (crate-source "quote" "1.0.45"
                "095rb5rg7pbnwdp6v8w5jw93wndwyijgci1b5lw8j1h5cscn3wj1"))

(define rust-r-efi-5.3.0
  (crate-source "r-efi" "5.3.0"
                "03sbfm3g7myvzyylff6qaxk4z6fy76yv860yy66jiswc2m6b7kb9"))

(define rust-r-efi-6.0.0
  (crate-source "r-efi" "6.0.0"
                "1gyrl2k5fyzj9k7kchg2n296z5881lg7070msabid09asp3wkp7q"))

(define rust-radicle-0.13.0
  (crate-source "radicle" "0.13.0"
                "0rd4wvgdbfk8rpmrljq22bir5v78iivjs04bydbaq6qzq5lqb0aa"))

(define rust-radicle-0.22.1
  (crate-source "radicle" "0.22.1"
                "16mkqd1xd0jvqla141nk56srz53b0iwrkbncgmks7cc7gfngrz1i"))

(define rust-radicle-ci-broker-0.27.0
  (crate-source "radicle-ci-broker" "0.27.0"
                "19ipgcpz6pii1plqngppj3bvsv4ypb929lis88gbcgqkbvgnpyha"))

(define rust-radicle-cob-0.12.0
  (crate-source "radicle-cob" "0.12.0"
                "1cqp3bg1wj2izbmkkd5ikyy9pdl0n23y9gklhvlbdzyqk54wkynl"))

(define rust-radicle-cob-0.19.0
  (crate-source "radicle-cob" "0.19.0"
                "17l3bidakzxf6g1s886hcc3wbjzknlxqgv6qrx9bl756n22bajfd"))

(define rust-radicle-core-0.2.0
  (crate-source "radicle-core" "0.2.0"
                "0c6xyx6sgk9l2816i04d9drgr3kz5kbscljh6l54fimrcar5ayv1"))

(define rust-radicle-crypto-0.11.0
  (crate-source "radicle-crypto" "0.11.0"
                "1bfnsb8xym3n40h2v833r8w45sv8cc09g5840snl363id5wsdmni"))

(define rust-radicle-crypto-0.16.0
  (crate-source "radicle-crypto" "0.16.0"
                "0798x36n94mm2kijxfqxmjbjzfqjjsq1p0isisaxwj74sc3g8z7p"))

(define rust-radicle-dag-0.10.0
  (crate-source "radicle-dag" "0.10.0"
                "0xa8c4mi4fwfrix923w9v8xd6mmgnjzrc2hrc3wlsfns1bhwfhfb"))

(define rust-radicle-dag-0.9.0
  (crate-source "radicle-dag" "0.9.0"
                "0rrh6108ii7qbjvncd7n19m0d7szkbm557yx6imax24s0k1pi9n2"))

(define rust-radicle-git-ext-0.12.0
  (crate-source "radicle-git-ext" "0.12.0"
                "03b76g3brwbz2j7n560m2c1yp6pq4iz4ys6s6fkm50vbmxxg8s6v"))

(define rust-radicle-git-ext-0.8.1
  (crate-source "radicle-git-ext" "0.8.1"
                "0l363i5gwnd3pl0f415cf89lc2b64cxsw0n6l3ajlwficxpc4y2b"))

(define rust-radicle-git-metadata-0.1.0
  (crate-source "radicle-git-metadata" "0.1.0"
                "1jzc4gj37nxfis98wqq4b26llbzvnyraxscnbldrhqgygnh7ybaj"))

(define rust-radicle-git-metadata-0.2.0
  (crate-source "radicle-git-metadata" "0.2.0"
                "1m8ax26q930db96i3y7zcsp9fvl4swr8xc04m3lz000gw351fy6v"))

(define rust-radicle-git-ref-format-0.1.0
  (crate-source "radicle-git-ref-format" "0.1.0"
                "0p6mprdkig4yyqficngnw599nr3rxywiwvass0aks6bw2fla9rvz"))

(define rust-radicle-job-0.5.2
  (crate-source "radicle-job" "0.5.2"
                "0hpykqr5n9sc4c5nhxiwfxg29nvhy2d0kqg4j68405cjccqryqhn"))

(define rust-radicle-localtime-0.1.0
  (crate-source "radicle-localtime" "0.1.0"
                "1pfxiz491sj0xzmgip8g46ss6jhs3h6xygpdz0hr9p1jzla6ghy5"))

(define rust-radicle-oid-0.1.0
  (crate-source "radicle-oid" "0.1.0"
                "1jaslz6g997047hfpg4b7b30rnalk10mdklgppvmwkwxb1plhp6r"))

(define rust-radicle-signals-0.10.0
  (crate-source "radicle-signals" "0.10.0"
                "0jgihm0sv91c0hswcq2yyi5z21n580yzhdfr6j6nwklnxpv6bfkz"))

(define rust-radicle-ssh-0.10.0
  (crate-source "radicle-ssh" "0.10.0"
                "1if9gsw21jhbd6ibj47ig1jf5s0pn4pq6bwbng6mgj6qb499wvi1"))

(define rust-radicle-ssh-0.9.0
  (crate-source "radicle-ssh" "0.9.0"
                "1ik6fd64idgdyknl7lahcjqibg1wxgxr31diwhmlhr7v2207bvpv"))

(define rust-radicle-std-ext-0.1.0
  (crate-source "radicle-std-ext" "0.1.0"
                "195aflsf8s6nqvgva0a54k1gl0j9kwv6qnlfxhzkzrlspimi686v"))

(define rust-radicle-std-ext-0.2.0
  (crate-source "radicle-std-ext" "0.2.0"
                "0wzci0mfcm1x36h67ifv7mqw0knmv4qk0ksq7dprd8njplqmk4zv"))

(define rust-radicle-surf-0.22.1
  (crate-source "radicle-surf" "0.22.1"
                "01dqxrrd5hsnyaj9f148vl94d3fgbkf6v0pp1chfgs10fpsszxhb"))

(define rust-radicle-surf-0.27.0
  (crate-source "radicle-surf" "0.27.0"
                "0265qj6dpnkzl9bx2q5y0wggn6p9rfrsx3rccg8acm9fmjga5ip2"))

(define rust-radicle-term-0.11.0
  (crate-source "radicle-term" "0.11.0"
                "067cra3pxx2rw3ybpp1chidki2yz4987avjz2g6xsgqfk1b35kyj"))

(define rust-rand-0.8.5
  (crate-source "rand" "0.8.5"
                "013l6931nn7gkc23jz5mm3qdhf93jjf0fg64nz2lp4i51qd8vbrl"))

(define rust-rand-chacha-0.3.1
  (crate-source "rand_chacha" "0.3.1"
                "123x2adin558xbhvqb8w4f6syjsdkmqff8cxwhmjacpsl1ihmhg6"))

(define rust-rand-core-0.10.1
  (crate-source "rand_core" "0.10.1"
                "0s9wiacxrr100icl7i41308gcj85nlcclrc5jx1jd6p10dhigf33"))

(define rust-rand-core-0.6.4
  (crate-source "rand_core" "0.6.4"
                "0b4j2v4cb5krak1pv6kakv4sz6xcwbrmy2zckc32hsigbrwy82zc"))

(define rust-rayon-1.11.0
  (crate-source "rayon" "1.11.0"
                "13x5fxb7rn4j2yw0cr26n7782jkc7rjzmdkg42qxk3xz0p8033rn"))

(define rust-rayon-core-1.13.0
  (crate-source "rayon-core" "1.13.0"
                "14dbr0sq83a6lf1rfjq5xdpk5r6zgzvmzs5j6110vlv2007qpq92"))

(define rust-redox-syscall-0.4.1
  (crate-source "redox_syscall" "0.4.1"
                "1aiifyz5dnybfvkk4cdab9p2kmphag1yad6iknc7aszlxxldf8j7"))

(define rust-redox-syscall-0.5.18
  (crate-source "redox_syscall" "0.5.18"
                "0b9n38zsxylql36vybw18if68yc9jczxmbyzdwyhb9sifmag4azd"))

(define rust-redox-syscall-0.5.7
  (crate-source "redox_syscall" "0.5.7"
                "07vpgfr6a04k0x19zqr1xdlqm6fncik3zydbdi3f5g3l5k7zwvcv"))

(define rust-redox-syscall-0.7.3
  (crate-source "redox_syscall" "0.7.3"
                "05mys0g4faa5l7dqvl4y8395b42yshs2qlvysdvijlwhx1s0mrvc"))

(define rust-redox-termios-0.1.3
  (crate-source "redox_termios" "0.1.3"
                "1jzifsj7fqyksz4325l3azfzpyv027kjabf93zcmass3p9q5c510"))

(define rust-ref-cast-1.0.25
  (crate-source "ref-cast" "1.0.25"
                "0zdzc34qjva9xxgs889z5iz787g81hznk12zbk4g2xkgwq530m7k"))

(define rust-ref-cast-impl-1.0.25
  (crate-source "ref-cast-impl" "1.0.25"
                "1nkhn1fklmn342z5c4mzfzlxddv3x8yhxwwk02cj06djvh36065p"))

(define rust-regex-1.11.0
  (crate-source "regex" "1.11.0"
                "1n5imk7yxam409ik5nagsjpwqvbg3f0g0mznd5drf549x1g0w81q"))

(define rust-regex-1.12.3
  (crate-source "regex" "1.12.3"
                "0xp2q0x7ybmpa5zlgaz00p8zswcirj9h8nry3rxxsdwi9fhm81z1"))

(define rust-regex-automata-0.1.10
  (crate-source "regex-automata" "0.1.10"
                "0ci1hvbzhrfby5fdpf4ganhf7kla58acad9i1ff1p34dzdrhs8vc"))

(define rust-regex-automata-0.4.14
  (crate-source "regex-automata" "0.4.14"
                "13xf7hhn4qmgfh784llcp2kzrvljd13lb2b1ca0mwnf15w9d87bf"))

(define rust-regex-automata-0.4.8
  (crate-source "regex-automata" "0.4.8"
                "18wd530ndrmygi6xnz3sp345qi0hy2kdbsa89182nwbl6br5i1rn"))

(define rust-regex-syntax-0.6.29
  (crate-source "regex-syntax" "0.6.29"
                "1qgj49vm6y3zn1hi09x91jvgkl2b1fiaq402skj83280ggfwcqpi"))

(define rust-regex-syntax-0.8.10
  (crate-source "regex-syntax" "0.8.10"
                "02jx311ka0daxxc7v45ikzhcl3iydjbbb0mdrpc1xgg8v7c7v2fw"))

(define rust-regex-syntax-0.8.5
  (crate-source "regex-syntax" "0.8.5"
                "0p41p3hj9ww7blnbwbj9h7rwxzxg0c1hvrdycgys8rxyhqqw859b"))

(define rust-remove-dir-all-1.0.0
  (crate-source "remove_dir_all" "1.0.0"
                "026xl6wlkjxksm1n3dcccygssami56aa937h6vgnmxxcfnsc1340"))

(define rust-rfc6979-0.4.0
  (crate-source "rfc6979" "0.4.0"
                "1chw95jgcfrysyzsq6a10b1j5qb7bagkx8h0wda4lv25in02mpgq"))

(define rust-rns-core-0.1.17
  (crate-source "rns-core" "0.1.17"
                "0j08y9xybc5ys6fj32zb8c8khpggzplq187z4ndabf207b96i9ad"))

(define rust-rns-core-0.1.7
  (crate-source "rns-core" "0.1.7"
                "0yd6dpban03m88g6rmhxmc1s4fzl9rc6fxv8frbxrw45pqqbk3zm"))

(define rust-rns-crypto-0.1.10
  (crate-source "rns-crypto" "0.1.10"
                "000j19xc7x6n526s96qmsj0891igqqca1w6pyfflbyz8c3m1szlv"))

(define rust-rns-crypto-0.1.4
  (crate-source "rns-crypto" "0.1.4"
                "0xjc1lhjvf4jq3b6dmnf11rn83xjmq7qmdkny5s2ir3gw35p56gd"))

(define rust-rns-net-0.5.4
  (crate-source "rns-net" "0.5.4"
                "0wsp2pm9s1hwnfr808ngan7s6xj928gr1lnxgqwzq8cnzxgcw6g8"))

(define rust-rns-net-0.7.1
  (crate-source "rns-net" "0.7.1"
                "04v3q38nh5xgmdypabld6mcnfx1k983xn12spi7zvz2vk4c2r3kp"))

(define rust-roadmap-0.7.0
  (crate-source "roadmap" "0.7.0"
                "0xwzxsh3qk5mg7yfsjxjm6x68adp5c8szv7dznzf9irla5f7fjgc"))

(define rust-rsa-0.9.10
  (crate-source "rsa" "0.9.10"
                "0bdikdwhcvl1gfh4637m5rdw3fgcl752aiygvzmwlgc8yl1kymxq"))

(define rust-rsa-0.9.6
  (crate-source "rsa" "0.9.6"
                "1z0d1aavfm0v4pv8jqmqhhvvhvblla1ydzlvwykpc3mkzhj523jx"))

(define rust-rss-2.0.12
  (crate-source "rss" "2.0.12"
                "1gvidz2b2vqkq8g1xbyxn8cdkd9sppix6vzmj450yrh3y0w7f45j"))

(define rust-rust-decimal-1.40.0
  (crate-source "rust_decimal" "1.40.0"
                "1c1yb8lms5aqzlaarwa0d7mn30s2h7x46djipiyginsjk38h7xv1"))

(define rust-rustc-demangle-0.1.24
  (crate-source "rustc-demangle" "0.1.24"
                "07zysaafgrkzy2rjgwqdj2a8qdpsm6zv6f5pgpk9x0lm40z9b6vi"))

(define rust-rustc-version-0.4.1
  (crate-source "rustc_version" "0.4.1"
                "14lvdsmr5si5qbqzrajgb6vfn69k0sfygrvfvr2mps26xwi3mjyg"))

(define rust-rustix-0.38.37
  (crate-source "rustix" "0.38.37"
                "04b8f99c2g36gyggf4aphw8742k2b1vls3364n2z493whj5pijwa"))

(define rust-rustix-1.1.4
  (crate-source "rustix" "1.1.4"
                "14511f9yjqh0ix07xjrjpllah3325774gfwi9zpq72sip5jlbzmn"))

(define rust-rustversion-1.0.18
  (crate-source "rustversion" "1.0.18"
                "0j2207vmgrcxwwwvknfn3lwv4i8djhjnxlvwdnz8bwijqqmrz08f"))

(define rust-rustversion-1.0.22
  (crate-source "rustversion" "1.0.22"
                "0vfl70jhv72scd9rfqgr2n11m5i9l1acnk684m2w83w0zbqdx75k"))

(define rust-ryu-1.0.18
  (crate-source "ryu" "1.0.18"
                "17xx2s8j1lln7iackzd9p0sv546vjq71i779gphjq923vjh5pjzk"))

(define rust-ryu-1.0.23
  (crate-source "ryu" "1.0.23"
                "0zs70sg00l2fb9jwrf6cbkdyscjs53anrvai2hf7npyyfi5blx4p"))

(define rust-same-file-1.0.6
  (crate-source "same-file" "1.0.6"
                "00h5j1w87dmhnvbv9l8bic3y7xxsnjmssvifw2ayvgx9mb1ivz4k"))

(define rust-schemars-1.2.1
  (crate-source "schemars" "1.2.1"
                "1k16qzpdpy6p9hrh18q2l6cwawxzyqi25f8masa13l0wm8v2zd52"))

(define rust-schemars-derive-1.2.1
  (crate-source "schemars_derive" "1.2.1"
                "0zrh1ckcc63sqy5hyhnh2lbxh4vmbij2z4f1g5za1vmayi85n4bx"))

(define rust-scoped-tls-1.0.1
  (crate-source "scoped-tls" "1.0.1"
                "15524h04mafihcvfpgxd8f4bgc3k95aclz8grjkg9a0rxcvn9kz1"))

(define rust-scopeguard-1.2.0
  (crate-source "scopeguard" "1.2.0"
                "0jcz9sd47zlsgcnm1hdw0664krxwb5gczlif4qngj2aif8vky54l"))

(define rust-sec1-0.7.3
  (crate-source "sec1" "0.7.3"
                "1p273j8c87pid6a1iyyc7vxbvifrw55wbxgr0dh3l8vnbxb7msfk"))

(define rust-semver-1.0.27
  (crate-source "semver" "1.0.27"
                "1qmi3akfrnqc2hfkdgcxhld5bv961wbk8my3ascv5068mc5fnryp"))

(define rust-semver-1.0.28
  (crate-source "semver" "1.0.28"
                "1kaimrpy876bcgi8bfj0qqfxk77zm9iz2zhn1hp9hj685z854y4a"))

(define rust-serde-1.0.210
  (crate-source "serde" "1.0.210"
                "0flc0z8wgax1k4j5bf2zyq48bgzyv425jkd5w0i6wbh7f8j5kqy8"))

(define rust-serde-1.0.228
  (crate-source "serde" "1.0.228"
                "17mf4hhjxv5m90g42wmlbc61hdhlm6j9hwfkpcnd72rpgzm993ls"))

(define rust-serde-core-1.0.228
  (crate-source "serde_core" "1.0.228"
                "1bb7id2xwx8izq50098s5j2sqrrvk31jbbrjqygyan6ask3qbls1"))

(define rust-serde-derive-1.0.210
  (crate-source "serde_derive" "1.0.210"
                "07yzy4wafk79ps0hmbqmsqh5xjna4pm4q57wc847bb8gl3nh4f94"))

(define rust-serde-derive-1.0.228
  (crate-source "serde_derive" "1.0.228"
                "0y8xm7fvmr2kjcd029g9fijpndh8csv5m20g4bd76w8qschg4h6m"))

(define rust-serde-derive-internals-0.29.1
  (crate-source "serde_derive_internals" "0.29.1"
                "04g7macx819vbnxhi52cx0nhxi56xlhrybgwybyy7fb9m4h6mlhq"))

(define rust-serde-json-1.0.128
  (crate-source "serde_json" "1.0.128"
                "1n43nia50ybpcfmh3gcw4lcc627qsg9nyakzwgkk9pm10xklbxbg"))

(define rust-serde-json-1.0.149
  (crate-source "serde_json" "1.0.149"
                "11jdx4vilzrjjd1dpgy67x5lgzr0laplz30dhv75lnf5ffa07z43"))

(define rust-serde-norway-0.9.42
  (crate-source "serde_norway" "0.9.42"
                "130nx1r3nwydglq1yrrcydavd6w5zj219zsimc7m1zdmi6ag4274"))

(define rust-serde-path-to-error-0.1.16
  (crate-source "serde_path_to_error" "0.1.16"
                "19hlz2359l37ifirskpcds7sxg0gzpqvfilibs7whdys0128i6dg"))

(define rust-serde-path-to-error-0.1.20
  (crate-source "serde_path_to_error" "0.1.20"
                "0mxls44p2ycmnxh03zpnlxxygq42w61ws7ir7r0ba6rp5s1gza8h"))

(define rust-serde-untagged-0.1.9
  (crate-source "serde-untagged" "0.1.9"
                "0n2hdjzas7w949klw1rpfzmpc9sm4sz9sa664jz969id9a5g9ypr"))

(define rust-serde-urlencoded-0.7.1
  (crate-source "serde_urlencoded" "0.7.1"
                "1zgklbdaysj3230xivihs30qi5vkhigg323a9m62k8jwf4a1qjfk"))

(define rust-sha2-0.10.8
  (crate-source "sha2" "0.10.8"
                "1j1x78zk9il95w9iv46dh9wm73r6xrgj32y6lzzw7bxws9dbfgbr"))

(define rust-sha2-0.10.9
  (crate-source "sha2" "0.10.9"
                "10xjj843v31ghsksd9sl9y12qfc48157j1xpb8v1ml39jy0psl57"))

(define rust-sha2-0.11.0
  (crate-source "sha2" "0.11.0"
                "1x15x22c5yf54ac0np5bfqnq5x0hdw4wqzpi48zwn94ma0bsfss4"))

(define rust-sha3-0.10.8
  (crate-source "sha3" "0.10.8"
                "0q5s3qlwnk8d5j34jya98j1v2p3009wdmnqdza3yydwgi8kjv1vm"))

(define rust-sharded-slab-0.1.7
  (crate-source "sharded-slab" "0.1.7"
                "1xipjr4nqsgw34k7a2cgj9zaasl2ds6jwn89886kww93d32a637l"))

(define rust-shell-words-1.1.1
  (crate-source "shell-words" "1.1.1"
                "0xzd5p53xl0ndnk63r0by52rhdrh6pd37szfxszkg73zb6ffcvyw"))

(define rust-shlex-1.3.0
  (crate-source "shlex" "1.3.0"
                "0r1y6bv26c1scpxvhg2cabimrmwgbp4p3wy6syj9n0c4s3q2znhg"))

(define rust-signal-hook-registry-1.4.8
  (crate-source "signal-hook-registry" "1.4.8"
                "06vc7pmnki6lmxar3z31gkyg9cw7py5x9g7px70gy2hil75nkny4"))

(define rust-signature-1.6.4
  (crate-source "signature" "1.6.4"
                "0z3xg405pg827g6hfdprnszsdqkkbrsfx7f1dl04nv9g7cxks8vl"))

(define rust-signature-2.2.0
  (crate-source "signature" "2.2.0"
                "1pi9hd5vqfr3q3k49k37z06p7gs5si0in32qia4mmr1dancr6m3p"))

(define rust-signature-3.0.0
  (crate-source "signature" "3.0.0"
                "1x9pfp51h2a0xs4x768q5r0y9yazv5naf216mjw9q17hpbf6gm98"))

(define rust-simd-adler32-0.3.8
  (crate-source "simd-adler32" "0.3.8"
                "18lx2gdgislabbvlgw5q3j5ssrr77v8kmkrxaanp3liimp2sc873"))

(define rust-siphasher-1.0.1
  (crate-source "siphasher" "1.0.1"
                "17f35782ma3fn6sh21c027kjmd227xyrx06ffi8gw4xzv9yry6an"))

(define rust-siphasher-1.0.2
  (crate-source "siphasher" "1.0.2"
                "13k7cfbpcm8qgj9p2n8dwg9skv9s0hxk5my30j5chy1p4l78bamj"))

(define rust-slab-0.4.9
  (crate-source "slab" "0.4.9"
                "0rxvsgir0qw5lkycrqgb1cxsvxzjv9bmx73bk5y42svnzfba94lg"))

(define rust-slug-0.1.6
  (crate-source "slug" "0.1.6"
                "0977cyp88xrwbpmqwzafkvv8vm9i0gdb5zjskb6f6pg45vvq0al8"))

(define rust-smallvec-1.13.2
  (crate-source "smallvec" "1.13.2"
                "0rsw5samawl3wsw6glrsb127rx6sh89a8wyikicw6dkdcjd1lpiw"))

(define rust-smallvec-1.15.1
  (crate-source "smallvec" "1.15.1"
                "00xxdxxpgyq5vjnpljvkmy99xij5rxgh913ii1v16kzynnivgcb7"))

(define rust-smawk-0.3.2
  (crate-source "smawk" "0.3.2"
                "0344z1la39incggwn6nl45k8cbw2x10mr5j0qz85cdz9np0qihxp"))

(define rust-socket2-0.5.10
  (crate-source "socket2" "0.5.10"
                "0y067ki5q946w91xlz2sb175pnfazizva6fi3kfp639mxnmpc8z2"))

(define rust-socket2-0.5.7
  (crate-source "socket2" "0.5.7"
                "070r941wbq76xpy039an4pyiy3rfj7mp7pvibf1rcri9njq5wc6f"))

(define rust-socket2-0.6.3
  (crate-source "socket2" "0.6.3"
                "0gkjjcyn69hqhhlh5kl8byk5m0d7hyrp2aqwzbs3d33q208nwxis"))

(define rust-socks5-client-0.4.1
  (crate-source "socks5-client" "0.4.1"
                "0k1jpbpc0wqqqykz27706vj6rmsqqr66l01kss15vmmizbvdrizz"))

(define rust-spin-0.9.8
  (crate-source "spin" "0.9.8"
                "0rvam5r0p3a6qhc18scqpvpgb3ckzyqxpgdfyjnghh8ja7byi039"))

(define rust-spki-0.7.3
  (crate-source "spki" "0.7.3"
                "17fj8k5fmx4w9mp27l970clrh5qa7r5sjdvbsln987xhb34dc7nr"))

(define rust-sqlite-0.32.0
  (crate-source "sqlite" "0.32.0"
                "1rpqpkpxn2qdvghsnak2b73cn5ca37p6ri0ylyjdcmrq3481r003"))

(define rust-sqlite-0.37.0
  (crate-source "sqlite" "0.37.0"
                "10s7kkypkvnx5dkxdi1vaj8vby015irvmnqh757iadhrl40rqvpn"))

(define rust-sqlite3-src-0.5.1
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "sqlite3-src" "0.5.1"
                "0m74wrkpify3z0xvrw4i2yssn9m9sjwqa5ipk6aq6f7fl58mmjdz"))

(define rust-sqlite3-src-0.7.0
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "sqlite3-src" "0.7.0"
                "081i23jsrmzna0j2q63sb4ipz8pllnb1fhlywqrhlsw8c34d7dp5"))

(define rust-sqlite3-sys-0.15.2
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "sqlite3-sys" "0.15.2"
                "0fq6m21dnd5yqrzknsmnl2565nahdwa29s7x12xhxr1kjik2qxgj"))

(define rust-sqlite3-sys-0.18.0
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "sqlite3-sys" "0.18.0"
                "0fbh4rjq4kc1mx6rigap6xzl5n7skbi9wyhjh581sfn1mnbisy57"))

(define rust-ssh-cipher-0.2.0
  (crate-source "ssh-cipher" "0.2.0"
                "0kvq113x9fcy2jcxp00xk472zxm8d9zxxz2vyqx3rlzh88ki7b6a"))

(define rust-ssh-encoding-0.2.0
  (crate-source "ssh-encoding" "0.2.0"
                "05aavlhk68vm60vbw8lcgx1p5wry367ck8niij7af221xywl54pb"))

(define rust-ssh-key-0.6.7
  (crate-source "ssh-key" "0.6.7"
                "1hx8as8rvnk31ncqg7dlqgcw9bmngkznn3xamf6d010ggwlzb1iv"))

(define rust-stable-deref-trait-1.2.1
  (crate-source "stable_deref_trait" "1.2.1"
                "15h5h73ppqyhdhx6ywxfj88azmrpml9gl6zp3pwy2malqa6vxqkc"))

(define rust-state-0.6.0
  (crate-source "state" "0.6.0"
                "1n3n2h324h1y5zhaajh6kplvzfvg1l6hsr8siggmf4yq8m24m31b"))

(define rust-strsim-0.11.1
  (crate-source "strsim" "0.11.1"
                "0kzvqlw8hxqb7y598w1s0hxlnmi84sg5vsipp3yg5na5d1rvba3x"))

(define rust-subplot-0.14.0
  (crate-source "subplot" "0.14.0"
                "18g4lkq8djbc3k9ifb053p23jkxg86qrnv8r6wgp881nzlmgjlnf"))

(define rust-subplotlib-0.14.0
  (crate-source "subplotlib" "0.14.0"
                "0lnw9papb2cig1gv3rpy446zcd7aa227yffm0gs65fqyyz8q42a8"))

(define rust-subplotlib-derive-0.14.0
  (crate-source "subplotlib-derive" "0.14.0"
                "1093s39aacijiw9g50d9rkppf1cjhlhivckx0jllwh61kccah34f"))

(define rust-subtle-2.6.1
  (crate-source "subtle" "2.6.1"
                "14ijxaymghbl1p0wql9cib5zlwiina7kall6w7g89csprkgbvhhk"))

(define rust-syn-1.0.109
  (crate-source "syn" "1.0.109"
                "0ds2if4600bd59wsv7jjgfkayfzy3hnazs394kz6zdkmna8l3dkj"))

(define rust-syn-2.0.117
  (crate-source "syn" "2.0.117"
                "16cv7c0wbn8amxc54n4w15kxlx5ypdmla8s0gxr2l7bv7s0bhrg6"))

(define rust-syn-2.0.79
  (crate-source "syn" "2.0.79"
                "147mk4sgigmvsb9l8qzj199ygf0fgb0bphwdsghn8205pz82q4w9"))

(define rust-sync-ptr-0.1.4
  (crate-source "sync-ptr" "0.1.4"
                "0kva6631hw8k866kmhrfiiagmxms2nmlh3hfyljidla2qx65n49b"))

(define rust-sync-wrapper-0.1.2
  (crate-source "sync_wrapper" "0.1.2"
                "0q01lyj0gr9a93n10nxsn8lwbzq97jqd6b768x17c8f7v7gccir0"))

(define rust-sync-wrapper-1.0.1
  (crate-source "sync_wrapper" "1.0.1"
                "150k6lwvr4nl237ngsz8fj5j78k712m4bggrfyjsidllraz5l1m7"))

(define rust-synstructure-0.13.2
  (crate-source "synstructure" "0.13.2"
                "1lh9lx3r3jb18f8sbj29am5hm9jymvbwh6jb1izsnnxgvgrp12kj"))

(define rust-tar-0.4.42
  (crate-source "tar" "0.4.42"
                "0820y2jdzx77i1m7r5rxwv8ks1mb2ynnkxn6axmy1dgd786w9xjg"))

(define rust-tar-0.4.45
  (crate-source "tar" "0.4.45"
                "0wq90hif25348zrvmk88q01g8aj8v8pla7f1vxgsf7x2frj2ls92"))

(define rust-tempfile-3.13.0
  (crate-source "tempfile" "3.13.0"
                "0nyagmbd4v5g6nzfydiihcn6l9j1w9bxgzyca5lyzgnhcbyckwph"))

(define rust-tempfile-3.27.0
  (crate-source "tempfile" "3.27.0"
                "1gblhnyfjsbg9wjg194n89wrzah7jy3yzgnyzhp56f3v9jd7wj9j"))

(define rust-tera-1.20.1
  (crate-source "tera" "1.20.1"
                "08k743nwb2mykpbwnipa1k3v8b1igg39pmdc7ggk4b8z5354n078"))

(define rust-terminal-size-0.4.3
  (crate-source "terminal_size" "0.4.3"
                "1l7cicmz49c0cyskfp5a389rsai649xi7y032v73475ikjbwpf30"))

(define rust-terminal-size-0.4.4
  (crate-source "terminal_size" "0.4.4"
                "0x4839vhhpzacc42rqj2wjhivlhlggzz3890b0c5pmyb3j11n2i3"))

(define rust-termion-2.0.3
  (crate-source "termion" "2.0.3"
                "0zcxsj2mms9hv8gizg2x3358ibjynzwvj5w6asr4683gxxyqqr64"))

(define rust-termion-3.0.0
  (crate-source "termion" "3.0.0"
                "19f7q542ih13j13jp5lr750z5yav7v035pmz46zznkahb9ki6y21"))

(define rust-textwrap-0.16.2
  (crate-source "textwrap" "0.16.2"
                "0mrhd8q0dnh5hwbwhiv89c6i41yzmhw4clwa592rrp24b9hlfdf1"))

(define rust-thiserror-1.0.64
  (crate-source "thiserror" "1.0.64"
                "114s8lmssxl0c2480s671am88vzlasbaikxbvfv8pyqrq6mzh2nm"))

(define rust-thiserror-1.0.69
  (crate-source "thiserror" "1.0.69"
                "0lizjay08agcr5hs9yfzzj6axs53a2rgx070a1dsi3jpkcrzbamn"))

(define rust-thiserror-2.0.18
  (crate-source "thiserror" "2.0.18"
                "1i7vcmw9900bvsmay7mww04ahahab7wmr8s925xc083rpjybb222"))

(define rust-thiserror-impl-1.0.64
  (crate-source "thiserror-impl" "1.0.64"
                "1hvzmjx9iamln854l74qyhs0jl2pg3hhqzpqm9p8gszmf9v4x408"))

(define rust-thiserror-impl-1.0.69
  (crate-source "thiserror-impl" "1.0.69"
                "1h84fmn2nai41cxbhk6pqf46bxqq1b344v8yz089w1chzi76rvjg"))

(define rust-thiserror-impl-2.0.18
  (crate-source "thiserror-impl" "2.0.18"
                "1mf1vrbbimj1g6dvhdgzjmn6q09yflz2b92zs1j9n3k7cxzyxi7b"))

(define rust-thread-local-1.1.8
  (crate-source "thread_local" "1.1.8"
                "173i5lyjh011gsimk21np9jn8al18rxsrkjli20a7b8ks2xgk7lb"))

(define rust-thread-local-1.1.9
  (crate-source "thread_local" "1.1.9"
                "1191jvl8d63agnq06pcnarivf63qzgpws5xa33hgc92gjjj4c0pn"))

(define rust-time-0.3.36
  (crate-source "time" "0.3.36"
                "11g8hdpahgrf1wwl2rpsg5nxq3aj7ri6xr672v4qcij6cgjqizax"))

(define rust-time-0.3.47
  (crate-source "time" "0.3.47"
                "0b7g9ly2iabrlgizliz6v5x23yq5d6bpp0mqz6407z1s526d8fvl"))

(define rust-time-core-0.1.2
  (crate-source "time-core" "0.1.2"
                "1wx3qizcihw6z151hywfzzyd1y5dl804ydyxci6qm07vbakpr4pg"))

(define rust-time-core-0.1.8
  (crate-source "time-core" "0.1.8"
                "1jidl426mw48i7hjj4hs9vxgd9lwqq4vyalm4q8d7y4iwz7y353n"))

(define rust-time-macros-0.2.18
  (crate-source "time-macros" "0.2.18"
                "1kqwxvfh2jkpg38fy673d6danh1bhcmmbsmffww3mphgail2l99z"))

(define rust-time-macros-0.2.27
  (crate-source "time-macros" "0.2.27"
                "058ja265waq275wxvnfwavbz9r1hd4dgwpfn7a1a9a70l32y8w1f"))

(define rust-tinystr-0.8.2
  (crate-source "tinystr" "0.8.2"
                "0sa8z88axdsf088hgw5p4xcyi6g3w3sgbb6qdp81bph9bk2fkls2"))

(define rust-tinyvec-1.11.0
  (crate-source "tinyvec" "1.11.0"
                "1wvycrghzmaysnw34kzwnf0mfx6r75045s24r214wnnjadqfcq9y"))

(define rust-tinyvec-1.8.0
  (crate-source "tinyvec" "1.8.0"
                "0f5rf6a2wzyv6w4jmfga9iw7rp9fp5gf4d604xgjsf3d9wgqhpj4"))

(define rust-tinyvec-macros-0.1.1
  (crate-source "tinyvec_macros" "0.1.1"
                "081gag86208sc3y6sdkshgw3vysm5d34p431dzw0bshz66ncng0z"))

(define rust-tokio-1.40.0
  (crate-source "tokio" "1.40.0"
                "166rllhfkyqp0fs7sxn6crv74iizi4wzd3cvxkcpmlk52qip1c72"))

(define rust-tokio-1.51.1
  (crate-source "tokio" "1.51.1"
                "131vl4p3hdn8kpvgv6qv06lspfxj7yvk9avq7r6p4jysbicgjszn"))

(define rust-tokio-macros-2.4.0
  (crate-source "tokio-macros" "2.4.0"
                "0lnpg14h1v3fh2jvnc8cz7cjf0m7z1xgkwfpcyy632g829imjgb9"))

(define rust-tokio-macros-2.7.0
  (crate-source "tokio-macros" "2.7.0"
                "15m4f37mdafs0gg36sh0rskm1i768lb7zmp8bw67kaxr3avnqniq"))

(define rust-tokio-util-0.7.12
  (crate-source "tokio-util" "0.7.12"
                "0spc0g4irbnf2flgag22gfii87avqzibwfm0si0d1g0k9ijw7rv1"))

(define rust-tokio-util-0.7.18
  (crate-source "tokio-util" "0.7.18"
                "1600rd47pylwn7cap1k7s5nvdaa9j7w8kqigzp1qy7mh0p4cxscs"))

(define rust-tower-0.4.13
  (crate-source "tower" "0.4.13"
                "073wncyqav4sak1p755hf6vl66njgfc1z1g1di9rxx3cvvh9pymq"))

(define rust-tower-0.5.1
  (crate-source "tower" "0.5.1"
                "0kvbp97bhb4sk24vhihcz74ngn0i4ygxqikmxndgng3w926r6wr8"))

(define rust-tower-http-0.6.1
  (crate-source "tower-http" "0.6.1"
                "15yb8rh970ll3yrd3lydshysi0x89bnxbqqrypqcbj5vnq51adw4"))

(define rust-tower-layer-0.3.3
  (crate-source "tower-layer" "0.3.3"
                "03kq92fdzxin51w8iqix06dcfgydyvx7yr6izjq0p626v9n2l70j"))

(define rust-tower-service-0.3.3
  (crate-source "tower-service" "0.3.3"
                "1hzfkvkci33ra94xjx64vv3pp0sq346w06fpkcdwjcid7zhvdycd"))

(define rust-tracing-0.1.40
  (crate-source "tracing" "0.1.40"
                "1vv48dac9zgj9650pg2b4d0j3w6f3x9gbggf43scq5hrlysklln3"))

(define rust-tracing-0.1.44
  (crate-source "tracing" "0.1.44"
                "006ilqkg1lmfdh3xhg3z762izfwmxcvz0w7m4qx2qajbz9i1drv3"))

(define rust-tracing-attributes-0.1.27
  (crate-source "tracing-attributes" "0.1.27"
                "1rvb5dn9z6d0xdj14r403z0af0bbaqhg02hq4jc97g5wds6lqw1l"))

(define rust-tracing-attributes-0.1.31
  (crate-source "tracing-attributes" "0.1.31"
                "1np8d77shfvz0n7camx2bsf1qw0zg331lra0hxb4cdwnxjjwz43l"))

(define rust-tracing-core-0.1.32
  (crate-source "tracing-core" "0.1.32"
                "0m5aglin3cdwxpvbg6kz0r9r0k31j48n0kcfwsp6l49z26k3svf0"))

(define rust-tracing-core-0.1.36
  (crate-source "tracing-core" "0.1.36"
                "16mpbz6p8vd6j7sf925k9k8wzvm9vdfsjbynbmaxxyq6v7wwm5yv"))

(define rust-tracing-log-0.2.0
  (crate-source "tracing-log" "0.2.0"
                "1hs77z026k730ij1a9dhahzrl0s073gfa2hm5p0fbl0b80gmz1gf"))

(define rust-tracing-logfmt-0.3.5
  (crate-source "tracing-logfmt" "0.3.5"
                "1ga4yjiyy7vc6p6x25xzc9ac1g8cyq01yangkzsw6ygb5p94f7vb"))

(define rust-tracing-serde-0.2.0
  (crate-source "tracing-serde" "0.2.0"
                "1wbgzi364vzfswfkvy48a3p0z5xmv98sx342r57sil70ggmiljvh"))

(define rust-tracing-subscriber-0.3.18
  (crate-source "tracing-subscriber" "0.3.18"
                "12vs1bwk4kig1l2qqjbbn2nm5amwiqmkcmnznylzmnfvjy6083xd"))

(define rust-tracing-subscriber-0.3.23
  (crate-source "tracing-subscriber" "0.3.23"
                "06fkr0qhggvrs861d7f74pn3i3a10h5jsp4n70jj9ys5b675fzyb"))

(define rust-try-lock-0.2.5
  (crate-source "try-lock" "0.2.5"
                "0jqijrrvm1pyq34zn1jmy2vihd4jcrjlvsh4alkjahhssjnsn8g4"))

(define rust-typeid-1.0.3
  (crate-source "typeid" "1.0.3"
                "0727ypay2p6mlw72gz3yxkqayzdmjckw46sxqpaj08v0b0r64zdw"))

(define rust-typenum-1.17.0
  (crate-source "typenum" "1.17.0"
                "09dqxv69m9lj9zvv6xw5vxaqx15ps0vxyy5myg33i0kbqvq0pzs2"))

(define rust-typenum-1.19.0
  (crate-source "typenum" "1.19.0"
                "1fw2mpbn2vmqan56j1b3fbpcdg80mz26fm53fs16bq5xcq84hban"))

(define rust-typenum-1.20.1
  (crate-source "typenum" "1.20.1"
                "086s9ly0906kw5yw41249fba97w5zfxf03pyfwdkffvcprqfixdn"))

(define rust-ucd-trie-0.1.7
  (crate-source "ucd-trie" "0.1.7"
                "0wc9p07sqwz320848i52nvyjvpsxkx3kv5bfbmm6s35809fdk5i8"))

(define rust-uds-windows-1.2.1
  (crate-source "uds_windows" "1.2.1"
                "0vidqwwfgn8wyzvbxiqil787b4wyqjia50zpdbbjqx7n8wlgpxpj"))

(define rust-unicase-2.9.0
  (crate-source "unicase" "2.9.0"
                "0hh1wrfd7807mfph2q67jsxqgw8hm82xg2fb8ln8cvblkwxbri6v"))

(define rust-unicode-bidi-0.3.17
  (crate-source "unicode-bidi" "0.3.17"
                "14vqdsnrm3y5anj6h5zz5s32w88crraycblb88d9k23k9ns7vcas"))

(define rust-unicode-display-width-0.3.0
  (crate-source "unicode-display-width" "0.3.0"
                "1wqb96ir19flkf557ch6lzng0mf2hzz52lz6p0mslh31clxjfhws"))

(define rust-unicode-ident-1.0.13
  (crate-source "unicode-ident" "1.0.13"
                "1zm1xylzsdfvm2a5ib9li3g5pp7qnkv4amhspydvgbmd9k6mc6z9"))

(define rust-unicode-ident-1.0.24
  (crate-source "unicode-ident" "1.0.24"
                "0xfs8y1g7syl2iykji8zk5hgfi5jw819f5zsrbaxmlzwsly33r76"))

(define rust-unicode-linebreak-0.1.5
  (crate-source "unicode-linebreak" "0.1.5"
                "07spj2hh3daajg335m4wdav6nfkl0f6c0q72lc37blr97hych29v"))

(define rust-unicode-normalization-0.1.24
  (crate-source "unicode-normalization" "0.1.24"
                "0mnrk809z3ix1wspcqy97ld5wxdb31f3xz6nsvg5qcv289ycjcsh"))

(define rust-unicode-normalization-0.1.25
  (crate-source "unicode-normalization" "0.1.25"
                "1s76dcrxw7vs32yhpi0p074apdc3s7lak7809f3qvclwij3zdm2z"))

(define rust-unicode-segmentation-1.12.0
  (crate-source "unicode-segmentation" "1.12.0"
                "14qla2jfx74yyb9ds3d2mpwpa4l4lzb9z57c6d2ba511458z5k7n"))

(define rust-unicode-width-0.1.14
  (crate-source "unicode-width" "0.1.14"
                "1bzn2zv0gp8xxbxbhifw778a7fc93pa6a1kj24jgg9msj07f7mkx"))

(define rust-unicode-width-0.2.2
  (crate-source "unicode-width" "0.2.2"
                "0m7jjzlcccw716dy9423xxh0clys8pfpllc5smvfxrzdf66h9b5l"))

(define rust-unicode-xid-0.2.6
  (crate-source "unicode-xid" "0.2.6"
                "0lzqaky89fq0bcrh6jj6bhlz37scfd8c7dsj5dq7y32if56c1hgb"))

(define rust-universal-hash-0.5.1
  (crate-source "universal-hash" "0.5.1"
                "1sh79x677zkncasa95wz05b36134822w6qxmi1ck05fwi33f47gw"))

(define rust-unsafe-libyaml-norway-0.2.15
  (crate-source "unsafe-libyaml-norway" "0.2.15"
                "0111lbq845fwqv8cn89m02v7bjd2lq2jvd814dziqlijpxcvv6mk"))

(define rust-ureq-2.10.1
  (crate-source "ureq" "2.10.1"
                "0jkgjllj1flrsv55q0bhbn7kmb03bxsm8iq5yxrk7gi5g2swckxp"))

(define rust-url-2.5.2
  (crate-source "url" "2.5.2"
                "0v2dx50mx7xzl9454cl5qmpjnhkbahmn59gd3apyipbgyyylsy12"))

(define rust-url-2.5.8
  (crate-source "url" "2.5.8"
                "1v8f7nx3hpr1qh76if0a04sj08k86amsq4h8cvpw6wvk76jahrzz"))

(define rust-utf8-iter-1.0.4
  (crate-source "utf8_iter" "1.0.4"
                "1gmna9flnj8dbyd8ba17zigrp9c4c3zclngf5lnb5yvz1ri41hdn"))

(define rust-utf8-width-0.1.8
  (crate-source "utf8-width" "0.1.8"
                "14d08vrz878wqpmqw46yl5l1vwmdf00zx4i49z8iahdmf3cw14hj"))

(define rust-utf8parse-0.2.2
  (crate-source "utf8parse" "0.2.2"
                "088807qwjq46azicqwbhlmzwrbkz7l4hpw43sdkdyyk524vdxaq6"))

(define rust-uuid-1.22.0
  (crate-source "uuid" "1.22.0"
                "0dvsfn44sddhyhlhk7m3i559wyb125h86799fm5abky0067kr3d6"))

(define rust-valuable-0.1.0
  (crate-source "valuable" "0.1.0"
                "0v9gp3nkjbl30z0fd56d8mx7w1csk86wwjhfjhr400wh9mfpw2w3"))

(define rust-valuable-0.1.1
  (crate-source "valuable" "0.1.1"
                "0r9srp55v7g27s5bg7a2m095fzckrcdca5maih6dy9bay6fflwxs"))

(define rust-valuable-serde-0.1.1
  (crate-source "valuable-serde" "0.1.1"
                "1cccgaa2q3ih6fy3x8x4kddjf0kx7f98jxz6wxxr06ydvs759q1f"))

(define rust-vcpkg-0.2.15
  (crate-source "vcpkg" "0.2.15"
                "09i4nf5y8lig6xgj3f7fyrvzd3nlaw4znrihw8psidvv5yk4xkdc"))

(define rust-version-check-0.9.5
  (crate-source "version_check" "0.9.5"
                "0nhhi4i5x89gm911azqbn7avs9mdacw2i3vcz3cnmz3mv4rqz4hb"))

(define rust-walkdir-2.5.0
  (crate-source "walkdir" "2.5.0"
                "0jsy7a710qv8gld5957ybrnc07gavppp963gs32xk4ag8130jy99"))

(define rust-want-0.3.1
  (crate-source "want" "0.3.1"
                "03hbfrnvqqdchb5kgxyavb9jabwza0dmh2vw5kg0dq8rxl57d9xz"))

(define rust-wasi-0.11.0+wasi-snapshot-preview1
  (crate-source "wasi" "0.11.0+wasi-snapshot-preview1"
                "08z4hxwkpdpalxjps1ai9y7ihin26y9f476i53dv98v45gkqg3cw"))

(define rust-wasi-0.11.1+wasi-snapshot-preview1
  (crate-source "wasi" "0.11.1+wasi-snapshot-preview1"
                "0jx49r7nbkbhyfrfyhz0bm4817yrnxgd3jiwwwfv0zl439jyrwyc"))

(define rust-wasip2-1.0.2+wasi-0.2.9
  (crate-source "wasip2" "1.0.2+wasi-0.2.9"
                "1xdw7v08jpfjdg94sp4lbdgzwa587m5ifpz6fpdnkh02kwizj5wm"))

(define rust-wasip3-0.4.0+wasi-0.3.0-rc-2026-01-06
  (crate-source "wasip3" "0.4.0+wasi-0.3.0-rc-2026-01-06"
                "19dc8p0y2mfrvgk3qw3c3240nfbylv22mvyxz84dqpgai2zzha2l"))

(define rust-wasm-bindgen-0.2.114
  (crate-source "wasm-bindgen" "0.2.114"
                "13nkhw552hpllrrmkd2x9y4bmcxr82kdpky2n667kqzcq6jzjck5"))

(define rust-wasm-bindgen-0.2.95
  (crate-source "wasm-bindgen" "0.2.95"
                "0bpbvmxhil380gpv53smaypl8wc7sy7rq8apxfw349pn78v1x38j"))

(define rust-wasm-bindgen-backend-0.2.95
  (crate-source "wasm-bindgen-backend" "0.2.95"
                "0n53wgy78bgzgjwk0z69zbspzhv8p2a4zh69s4fzvpqdrb9x8vfb"))

(define rust-wasm-bindgen-macro-0.2.114
  (crate-source "wasm-bindgen-macro" "0.2.114"
                "1rhq9kkl7n0zjrag9p25xsi4aabpgfkyf02zn4xv6pqhrw7xb8hq"))

(define rust-wasm-bindgen-macro-0.2.95
  (crate-source "wasm-bindgen-macro" "0.2.95"
                "0mic8b2vab1a91m6x3hjxkwz23094bq1cwhnszarsnlggyz894z7"))

(define rust-wasm-bindgen-macro-support-0.2.114
  (crate-source "wasm-bindgen-macro-support" "0.2.114"
                "1qriqqjpn922kv5c7f7627fj823k5aifv06j2gvwsiy5map4rkh3"))

(define rust-wasm-bindgen-macro-support-0.2.95
  (crate-source "wasm-bindgen-macro-support" "0.2.95"
                "0s7g6glb85lyx2pj83shbmg4d50mvqhb2c2qk2j28yigaxbspii6"))

(define rust-wasm-bindgen-shared-0.2.114
  (crate-source "wasm-bindgen-shared" "0.2.114"
                "05lc6w64jxlk4wk8rjci4z61lhx2ams90la27a41gvi3qaw2d8vm"))

(define rust-wasm-bindgen-shared-0.2.95
  (crate-source "wasm-bindgen-shared" "0.2.95"
                "1386q7mvv5ky003hcc6yyxpid3y1m7fy0l920i3z3ab60vqhkz35"))

(define rust-wasm-encoder-0.244.0
  (crate-source "wasm-encoder" "0.244.0"
                "06c35kv4h42vk3k51xjz1x6hn3mqwfswycmr6ziky033zvr6a04r"))

(define rust-wasm-metadata-0.244.0
  (crate-source "wasm-metadata" "0.244.0"
                "02f9dhlnryd2l7zf03whlxai5sv26x4spfibjdvc3g9gd8z3a3mv"))

(define rust-wasmparser-0.244.0
  (crate-source "wasmparser" "0.244.0"
                "1zi821hrlsxfhn39nqpmgzc0wk7ax3dv6vrs5cw6kb0v5v3hgf27"))

(define rust-winapi-0.3.9
  (crate-source "winapi" "0.3.9"
                "06gl025x418lchw1wxj64ycr7gha83m44cjr5sarhynd9xkrm0sw"))

(define rust-winapi-i686-pc-windows-gnu-0.4.0
  (crate-source "winapi-i686-pc-windows-gnu" "0.4.0"
                "1dmpa6mvcvzz16zg6d5vrfy4bxgg541wxrcip7cnshi06v38ffxc"))

(define rust-winapi-util-0.1.11
  (crate-source "winapi-util" "0.1.11"
                "08hdl7mkll7pz8whg869h58c1r9y7in0w0pk8fm24qc77k0b39y2"))

(define rust-winapi-x86-64-pc-windows-gnu-0.4.0
  (crate-source "winapi-x86_64-pc-windows-gnu" "0.4.0"
                "0gqq64czqb64kskjryj8isp62m2sgvx25yyj3kpc2myh85w24bki"))

(define rust-windows-0.48.0
  (crate-source "windows" "0.48.0"
                "03vh89ilnxdxdh0n9np4ns4m10fvm93h3b0cc05ipg3qq1mqi1p6"))

(define rust-windows-0.58.0
  (crate-source "windows" "0.58.0"
                "1dkjj94b0gn91nn1n22cvm4afsj98f5qrhcl3112v6f4jcfx816x"))

(define rust-windows-aarch64-gnullvm-0.48.5
  (crate-source "windows_aarch64_gnullvm" "0.48.5"
                "1n05v7qblg1ci3i567inc7xrkmywczxrs1z3lj3rkkxw18py6f1b"))

(define rust-windows-aarch64-gnullvm-0.53.1
  (crate-source "windows_aarch64_gnullvm" "0.53.1"
                "0lqvdm510mka9w26vmga7hbkmrw9glzc90l4gya5qbxlm1pl3n59"))

(define rust-windows-aarch64-msvc-0.48.5
  (crate-source "windows_aarch64_msvc" "0.48.5"
                "1g5l4ry968p73g6bg6jgyvy9lb8fyhcs54067yzxpcpkf44k2dfw"))

(define rust-windows-aarch64-msvc-0.53.1
  (crate-source "windows_aarch64_msvc" "0.53.1"
                "01jh2adlwx043rji888b22whx4bm8alrk3khjpik5xn20kl85mxr"))

(define rust-windows-core-0.52.0
  (crate-source "windows-core" "0.52.0"
                "1nc3qv7sy24x0nlnb32f7alzpd6f72l4p24vl65vydbyil669ark"))

(define rust-windows-core-0.58.0
  (crate-source "windows-core" "0.58.0"
                "16czypy425jzmiys4yb3pwsh7cm6grxn9kjp889iqnf2r17d99kb"))

(define rust-windows-i686-gnu-0.48.5
  (crate-source "windows_i686_gnu" "0.48.5"
                "0gklnglwd9ilqx7ac3cn8hbhkraqisd0n83jxzf9837nvvkiand7"))

(define rust-windows-i686-gnu-0.53.1
  (crate-source "windows_i686_gnu" "0.53.1"
                "18wkcm82ldyg4figcsidzwbg1pqd49jpm98crfz0j7nqd6h6s3ln"))

(define rust-windows-i686-gnullvm-0.53.1
  (crate-source "windows_i686_gnullvm" "0.53.1"
                "030qaxqc4salz6l4immfb6sykc6gmhyir9wzn2w8mxj8038mjwzs"))

(define rust-windows-i686-msvc-0.48.5
  (crate-source "windows_i686_msvc" "0.48.5"
                "01m4rik437dl9rdf0ndnm2syh10hizvq0dajdkv2fjqcywrw4mcg"))

(define rust-windows-i686-msvc-0.53.1
  (crate-source "windows_i686_msvc" "0.53.1"
                "1hi6scw3mn2pbdl30ji5i4y8vvspb9b66l98kkz350pig58wfyhy"))

(define rust-windows-implement-0.58.0
  (crate-source "windows-implement" "0.58.0"
                "16spr5z65z21qyv379rv2mb1s5q2i9ibd1p2pkn0dr9qr535pg9b"))

(define rust-windows-interface-0.58.0
  (crate-source "windows-interface" "0.58.0"
                "059mxmfvx3x88q74ms0qlxmj2pnidmr5mzn60hakn7f95m34qg05"))

(define rust-windows-link-0.2.1
  (crate-source "windows-link" "0.2.1"
                "1rag186yfr3xx7piv5rg8b6im2dwcf8zldiflvb22xbzwli5507h"))

(define rust-windows-result-0.2.0
  (crate-source "windows-result" "0.2.0"
                "03mf2z1xcy2slhhsm15z24p76qxgm2m74xdjp8bihyag47c4640x"))

(define rust-windows-strings-0.1.0
  (crate-source "windows-strings" "0.1.0"
                "042dxvi3133f7dyi2pgcvknwkikk47k8bddwxbq5s0l6qhjv3nac"))

(define rust-windows-sys-0.52.0
  (crate-source "windows-sys" "0.52.0"
                "0gd3v4ji88490zgb6b5mq5zgbvwv7zx1ibn8v3x83rwcdbryaar8"))

(define rust-windows-sys-0.59.0
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "windows-sys" "0.59.0"
                "0fw5672ziw8b3zpmnbp9pdv1famk74f1l9fcbc3zsrzdg56vqf0y"))

(define rust-windows-sys-0.60.2
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "windows-sys" "0.60.2"
                "1jrbc615ihqnhjhxplr2kw7rasrskv9wj3lr80hgfd42sbj01xgj"))

(define rust-windows-sys-0.61.2
  (crate-source "windows-sys" "0.61.2"
                "1z7k3y9b6b5h52kid57lvmvm05362zv1v8w0gc7xyv5xphlp44xf"))

(define rust-windows-targets-0.48.5
  (crate-source "windows-targets" "0.48.5"
                "034ljxqshifs1lan89xwpcy1hp0lhdh4b5n0d2z4fwjx2piacbws"))

(define rust-windows-targets-0.52.6
  (crate-source "windows-targets" "0.52.6"
                "0wwrx625nwlfp7k93r2rra568gad1mwd888h1jwnl0vfg5r4ywlv"))

(define rust-windows-aarch64-gnullvm-0.52.6
  (crate-source "windows_aarch64_gnullvm" "0.52.6"
                "1lrcq38cr2arvmz19v32qaggvj8bh1640mdm9c2fr877h0hn591j"))

(define rust-windows-aarch64-msvc-0.52.6
  (crate-source "windows_aarch64_msvc" "0.52.6"
                "0sfl0nysnz32yyfh773hpi49b1q700ah6y7sacmjbqjjn5xjmv09"))

(define rust-windows-i686-gnu-0.52.6
  (crate-source "windows_i686_gnu" "0.52.6"
                "02zspglbykh1jh9pi7gn8g1f97jh1rrccni9ivmrfbl0mgamm6wf"))

(define rust-windows-i686-gnullvm-0.52.6
  (crate-source "windows_i686_gnullvm" "0.52.6"
                "0rpdx1537mw6slcpqa0rm3qixmsb79nbhqy5fsm3q2q9ik9m5vhf"))

(define rust-windows-i686-msvc-0.52.6
  (crate-source "windows_i686_msvc" "0.52.6"
                "0rkcqmp4zzmfvrrrx01260q3xkpzi6fzi2x2pgdcdry50ny4h294"))

(define rust-windows-targets-0.53.5
  (crate-source "windows-targets" "0.53.5"
                "1wv9j2gv3l6wj3gkw5j1kr6ymb5q6dfc42yvydjhv3mqa7szjia9"))

(define rust-windows-x86-64-gnu-0.48.5
  (crate-source "windows_x86_64_gnu" "0.48.5"
                "13kiqqcvz2vnyxzydjh73hwgigsdr2z1xpzx313kxll34nyhmm2k"))

(define rust-windows-x86-64-gnu-0.52.6
  (crate-source "windows_x86_64_gnu" "0.52.6"
                "0y0sifqcb56a56mvn7xjgs8g43p33mfqkd8wj1yhrgxzma05qyhl"))

(define rust-windows-x86-64-gnu-0.53.1
  (crate-source "windows_x86_64_gnu" "0.53.1"
                "16d4yiysmfdlsrghndr97y57gh3kljkwhfdbcs05m1jasz6l4f4w"))

(define rust-windows-x86-64-gnullvm-0.48.5
  (crate-source "windows_x86_64_gnullvm" "0.48.5"
                "1k24810wfbgz8k48c2yknqjmiigmql6kk3knmddkv8k8g1v54yqb"))

(define rust-windows-x86-64-gnullvm-0.52.6
  (crate-source "windows_x86_64_gnullvm" "0.52.6"
                "03gda7zjx1qh8k9nnlgb7m3w3s1xkysg55hkd1wjch8pqhyv5m94"))

(define rust-windows-x86-64-gnullvm-0.53.1
  (crate-source "windows_x86_64_gnullvm" "0.53.1"
                "1qbspgv4g3q0vygkg8rnql5c6z3caqv38japiynyivh75ng1gyhg"))

(define rust-windows-x86-64-msvc-0.48.5
  (crate-source "windows_x86_64_msvc" "0.48.5"
                "0f4mdp895kkjh9zv8dxvn4pc10xr7839lf5pa9l0193i2pkgr57d"))

(define rust-windows-x86-64-msvc-0.52.6
  (crate-source "windows_x86_64_msvc" "0.52.6"
                "1v7rb5cibyzx8vak29pdrk8nx9hycsjs4w0jgms08qk49jl6v7sq"))

(define rust-windows-x86-64-msvc-0.53.1
  (crate-source "windows_x86_64_msvc" "0.53.1"
                "0l6npq76vlq4ksn4bwsncpr8508mk0gmznm6wnhjg95d19gzzfyn"))

(define rust-winnow-0.7.15
  (crate-source "winnow" "0.7.15"
                "0i9rkl2rqpbnnxlgs20gmkj3nd0b2k8q55mjmpc2ybb84xwxjyfz"))

(define rust-winpipe-0.1.1
  (crate-source "winpipe" "0.1.1"
                "0lv041gy68frc8ybi6l99ix1zdd6njdycnch7n8hrgfic8fngkqw"))

(define rust-wit-bindgen-0.51.0
  (crate-source "wit-bindgen" "0.51.0"
                "19fazgch8sq5cvjv3ynhhfh5d5x08jq2pkw8jfb05vbcyqcr496p"))

(define rust-wit-bindgen-core-0.51.0
  (crate-source "wit-bindgen-core" "0.51.0"
                "1p2jszqsqbx8k7y8nwvxg65wqzxjm048ba5phaq8r9iy9ildwqga"))

(define rust-wit-bindgen-rust-0.51.0
  (crate-source "wit-bindgen-rust" "0.51.0"
                "08bzn5fsvkb9x9wyvyx98qglknj2075xk1n7c5jxv15jykh6didp"))

(define rust-wit-bindgen-rust-macro-0.51.0
  (crate-source "wit-bindgen-rust-macro" "0.51.0"
                "0ymizapzv2id89igxsz2n587y2hlfypf6n8kyp68x976fzyrn3qc"))

(define rust-wit-component-0.244.0
  (crate-source "wit-component" "0.244.0"
                "1clwxgsgdns3zj2fqnrjcp8y5gazwfa1k0sy5cbk0fsmx4hflrlx"))

(define rust-wit-parser-0.244.0
  (crate-source "wit-parser" "0.244.0"
                "0dm7avvdxryxd5b02l0g5h6933z1cw5z0d4wynvq2cywq55srj7c"))

(define rust-writeable-0.6.2
  (crate-source "writeable" "0.6.2"
                "1fg08y97n6vk7l0rnjggw3xyrii6dcqg54wqaxldrlk98zdy1pcy"))

(define rust-x25519-dalek-2.0.1
  (crate-source "x25519-dalek" "2.0.1"
                "0xyjgqpsa0q6pprakdp58q1hy45rf8wnqqscgzx0gyw13hr6ir67"))

(define rust-x25519-dalek-3.0.0
  (crate-source "x25519-dalek" "3.0.0"
                "1xlsapsh4pgzk7rwdy3gdgjdmjif68mwgbv34bxjf08r0cd17s77"))

(define rust-xattr-1.3.1
  (crate-source "xattr" "1.3.1"
                "0kqxm36w89vc6qcpn6pizlhgjgzq138sx4hdhbv2g6wk4ld4za4d"))

(define rust-xattr-1.6.1
  (crate-source "xattr" "1.6.1"
                "0ml1mb43gqasawillql6b344m0zgq8mz0isi11wj8vbg43a5mr1j"))

(define rust-yaml-rust2-0.10.4
  (crate-source "yaml-rust2" "0.10.4"
                "1n8yc8biqq4ffkpaycxqa3kr0avzg09jw19xg7c9cm24kh1ylqi4"))

(define rust-yaml-rust2-0.9.0
  (crate-source "yaml-rust2" "0.9.0"
                "13ay8jdlk1192p6hhb53dx601b139ycizipqpnikhcw2r45iq6ia"))

(define rust-yansi-1.0.1
  (crate-source "yansi" "1.0.1"
                "0jdh55jyv0dpd38ij4qh60zglbw9aa8wafqai6m0wa7xaxk3mrfg"))

(define rust-yoke-0.8.1
  (crate-source "yoke" "0.8.1"
                "0m29dm0bf5iakxgma0bj6dbmc3b8qi9b1vaw9sa76kdqmz3fbmkj"))

(define rust-yoke-derive-0.8.1
  (crate-source "yoke-derive" "0.8.1"
                "0pbyja133jnng4mrhimzdq4a0y26421g734ybgz8wsgbfhl0andn"))

(define rust-zerocopy-0.7.35
  (crate-source "zerocopy" "0.7.35"
                "1w36q7b9il2flg0qskapgi9ymgg7p985vniqd09vi0mwib8lz6qv"))

(define rust-zerocopy-0.8.47
  (crate-source "zerocopy" "0.8.47"
                "11zdl3708210fsiax93qbvw8kiadg9lnzriw26xg44g35c32mfzg"))

(define rust-zerocopy-derive-0.7.35
  (crate-source "zerocopy-derive" "0.7.35"
                "0gnf2ap2y92nwdalzz3x7142f2b83sni66l39vxp2ijd6j080kzs"))

(define rust-zerocopy-derive-0.8.47
  (crate-source "zerocopy-derive" "0.8.47"
                "12dbrk2w8mszdq9v01ls930bi446iyk4llggxrx8whalkckcg2qf"))

(define rust-zerofrom-0.1.6
  (crate-source "zerofrom" "0.1.6"
                "19dyky67zkjichsb7ykhv0aqws3q0jfvzww76l66c19y6gh45k2h"))

(define rust-zerofrom-derive-0.1.6
  (crate-source "zerofrom-derive" "0.1.6"
                "00l5niw7c1b0lf1vhvajpjmcnbdp2vn96jg4nmkhq2db0rp5s7np"))

(define rust-zeroize-1.8.1
  (crate-source "zeroize" "1.8.1"
                "1pjdrmjwmszpxfd7r860jx54cyk94qk59x13sc307cvr5256glyf"))

(define rust-zeroize-1.8.2
  (crate-source "zeroize" "1.8.2"
                "1l48zxgcv34d7kjskr610zqsm6j2b4fcr2vfh9jm9j1jgvk58wdr"))

(define rust-zerotrie-0.2.3
  (crate-source "zerotrie" "0.2.3"
                "0lbqznlqazmrwwzslw0ci7p3pqxykrbfhq29npj0gmb2amxc2n9a"))

(define rust-zerovec-0.11.5
  (crate-source "zerovec" "0.11.5"
                "00m0p47k2g9mkv505hky5xh3r6ps7v8qc0dy4pspg542jj972a3c"))

(define rust-zerovec-derive-0.11.2
  (crate-source "zerovec-derive" "0.11.2"
                "1wsig4h5j7a1scd5hrlnragnazjny9qjc44hancb6p6a76ay7p7a"))

(define rust-zmij-1.0.21
  (crate-source "zmij" "1.0.21"
                "1amb5i6gz7yjb0dnmz5y669674pqmwbj44p4yfxfv2ncgvk8x15q"))

(define-cargo-inputs lookup-cargo-inputs
                     (radicle-ci-broker =>
                                        (list rust-adler2-2.0.1
                                         rust-aead-0.5.2
                                         rust-aes-0.8.4
                                         rust-aes-gcm-0.10.3
                                         rust-ahash-0.8.12
                                         rust-aho-corasick-1.1.4
                                         rust-aligned-0.4.3
                                         rust-amplify-4.9.0
                                         rust-amplify-derive-4.0.1
                                         rust-amplify-num-0.5.3
                                         rust-amplify-syn-2.0.1
                                         rust-anstream-1.0.0
                                         rust-anstyle-1.0.14
                                         rust-anstyle-parse-1.0.0
                                         rust-anstyle-query-1.1.5
                                         rust-anstyle-wincon-3.0.11
                                         rust-anyhow-1.0.102
                                         rust-arraydeque-0.5.1
                                         rust-arrayvec-0.7.6
                                         rust-as-slice-0.2.1
                                         rust-ascii-1.1.0
                                         rust-atom-syndication-0.12.7
                                         rust-autocfg-1.5.0
                                         rust-base-x-0.2.11
                                         rust-base16ct-0.2.0
                                         rust-base256emoji-1.0.2
                                         rust-base32-0.4.0
                                         rust-base64-0.21.7
                                         rust-base64-0.22.1
                                         rust-base64ct-1.8.3
                                         rust-bcrypt-pbkdf-0.10.0
                                         rust-bitflags-2.11.0
                                         rust-block-buffer-0.10.4
                                         rust-block-padding-0.3.3
                                         rust-blowfish-0.9.1
                                         rust-bstr-1.12.1
                                         rust-bumpalo-3.20.2
                                         rust-byteorder-1.5.0
                                         rust-bytesize-2.3.1
                                         rust-cbc-0.1.2
                                         rust-cc-1.2.57
                                         rust-cfg-if-1.0.4
                                         rust-cfg-aliases-0.2.1
                                         rust-chacha20-0.9.1
                                         rust-chrono-0.4.44
                                         rust-cipher-0.4.4
                                         rust-clap-4.6.0
                                         rust-clap-builder-4.6.0
                                         rust-clap-derive-4.6.0
                                         rust-clap-lex-1.1.0
                                         rust-colorchoice-1.0.5
                                         rust-const-oid-0.9.6
                                         rust-const-str-0.4.3
                                         rust-cpufeatures-0.2.17
                                         rust-crc32fast-1.5.0
                                         rust-crossbeam-channel-0.5.15
                                         rust-crossbeam-deque-0.8.6
                                         rust-crossbeam-epoch-0.9.18
                                         rust-crossbeam-utils-0.8.21
                                         rust-crypto-bigint-0.5.5
                                         rust-crypto-common-0.1.7
                                         rust-ct-codecs-1.1.6
                                         rust-ctr-0.9.2
                                         rust-culpa-1.0.2
                                         rust-culpa-macros-1.0.2
                                         rust-cvt-0.1.2
                                         rust-cypheraddr-0.4.0
                                         rust-cyphergraphy-0.3.0
                                         rust-cyphernet-0.5.2
                                         rust-darling-0.20.11
                                         rust-darling-core-0.20.11
                                         rust-darling-macro-0.20.11
                                         rust-data-encoding-2.10.0
                                         rust-data-encoding-macro-0.1.19
                                         rust-data-encoding-macro-internal-0.1.17
                                         rust-defer-heavy-0.1.0
                                         rust-der-0.7.10
                                         rust-deranged-0.5.8
                                         rust-derive-builder-0.20.2
                                         rust-derive-builder-core-0.20.2
                                         rust-derive-builder-macro-0.20.2
                                         rust-descape-3.0.0
                                         rust-deunicode-1.6.2
                                         rust-digest-0.10.7
                                         rust-diligent-date-parser-0.1.5
                                         rust-displaydoc-0.2.5
                                         rust-doc-comment-0.3.4
                                         rust-dunce-1.0.5
                                         rust-duration-str-0.21.0
                                         rust-dyn-clone-1.0.20
                                         rust-ec25519-0.1.0
                                         rust-ecdsa-0.16.9
                                         rust-ed25519-1.5.3
                                         rust-elliptic-curve-0.13.8
                                         rust-encoding-rs-0.8.35
                                         rust-equivalent-1.0.2
                                         rust-erased-serde-0.4.10
                                         rust-errno-0.3.14
                                         rust-fast-glob-0.3.3
                                         rust-fastrand-2.3.0
                                         rust-ff-0.13.1
                                         rust-filetime-0.2.27
                                         rust-find-msvc-tools-0.1.9
                                         rust-flate2-1.1.9
                                         rust-fnv-1.0.7
                                         rust-foldhash-0.1.5
                                         rust-form-urlencoded-1.2.2
                                         rust-fs2-0.4.3
                                         rust-fs-at-0.2.1
                                         rust-generator-0.7.5
                                         rust-generic-array-0.14.7
                                         rust-getopts-0.2.24
                                         rust-getrandom-0.2.17
                                         rust-getrandom-0.3.4
                                         rust-getrandom-0.4.2
                                         rust-ghash-0.5.1
                                         rust-git-ref-format-0.6.0
                                         rust-git-ref-format-core-0.6.0
                                         rust-git-ref-format-macro-0.6.0
                                         rust-git2-0.20.4
                                         rust-globset-0.4.18
                                         rust-globwalk-0.9.1
                                         rust-group-0.13.0
                                         rust-hashbrown-0.14.5
                                         rust-hashbrown-0.15.5
                                         rust-hashbrown-0.16.1
                                         rust-hashlink-0.9.1
                                         rust-hashlink-0.10.0
                                         rust-heck-0.5.0
                                         rust-hmac-0.12.1
                                         rust-html-escape-0.2.13
                                         rust-html-page-0.5.0
                                         rust-humansize-2.1.3
                                         rust-icu-collections-2.1.1
                                         rust-icu-locale-core-2.1.1
                                         rust-icu-normalizer-2.1.1
                                         rust-icu-normalizer-data-2.1.1
                                         rust-icu-properties-2.1.2
                                         rust-icu-properties-data-2.1.2
                                         rust-icu-provider-2.1.1
                                         rust-id-arena-2.3.0
                                         rust-ident-case-1.0.1
                                         rust-idna-1.1.0
                                         rust-idna-adapter-1.2.1
                                         rust-ignore-0.4.25
                                         rust-indexmap-2.13.0
                                         rust-inout-0.1.4
                                         rust-is-terminal-polyfill-1.70.2
                                         rust-itoa-1.0.18
                                         rust-jobserver-0.1.34
                                         rust-js-sys-0.3.91
                                         rust-keccak-0.1.6
                                         rust-lazy-static-1.5.0
                                         rust-leb128fmt-0.1.0
                                         rust-libc-0.2.183
                                         rust-libgit2-sys-0.18.3+1.9.2
                                         rust-libm-0.2.16
                                         rust-libredox-0.1.14
                                         rust-libz-sys-1.1.25
                                         rust-line-col-0.2.1
                                         rust-linux-raw-sys-0.12.1
                                         rust-litemap-0.8.1
                                         rust-log-0.4.29
                                         rust-loom-0.5.6
                                         rust-marked-yaml-0.7.2
                                         rust-marked-yaml-0.8.0
                                         rust-match-lookup-0.1.2
                                         rust-matchers-0.2.0
                                         rust-memchr-2.8.0
                                         rust-memoffset-0.9.1
                                         rust-miniz-oxide-0.8.9
                                         rust-multibase-0.9.2
                                         rust-never-0.1.0
                                         rust-nix-0.29.0
                                         rust-nonempty-0.9.0
                                         rust-nonempty-0.11.0
                                         rust-nonempty-0.12.0
                                         rust-normpath-1.5.0
                                         rust-nu-ansi-term-0.50.3
                                         rust-num-bigint-dig-0.8.6
                                         rust-num-conv-0.2.0
                                         rust-num-integer-0.1.46
                                         rust-num-iter-0.1.45
                                         rust-num-traits-0.2.19
                                         rust-once-cell-1.21.4
                                         rust-once-cell-polyfill-1.70.2
                                         rust-opaque-debug-0.3.1
                                         rust-p256-0.13.2
                                         rust-p384-0.13.1
                                         rust-p521-0.13.3
                                         rust-pbkdf2-0.12.2
                                         rust-pem-rfc7468-0.7.0
                                         rust-percent-encoding-2.3.2
                                         rust-pest-2.8.6
                                         rust-pest-derive-2.8.6
                                         rust-pest-generator-2.8.6
                                         rust-pest-meta-2.8.6
                                         rust-pikchr-0.1.4
                                         rust-pin-project-lite-0.2.17
                                         rust-pkcs1-0.7.5
                                         rust-pkcs8-0.10.2
                                         rust-pkg-config-0.3.32
                                         rust-plain-0.2.3
                                         rust-poly1305-0.8.0
                                         rust-polyval-0.6.2
                                         rust-potential-utf-0.1.4
                                         rust-powerfmt-0.2.0
                                         rust-ppv-lite86-0.2.21
                                         rust-prettyplease-0.2.37
                                         rust-primeorder-0.13.6
                                         rust-proc-macro-error-attr2-2.0.0
                                         rust-proc-macro-error2-2.0.1
                                         rust-proc-macro2-1.0.106
                                         rust-pulldown-cmark-0.13.3
                                         rust-pulldown-cmark-escape-0.11.0
                                         rust-qcheck-1.0.0
                                         rust-qcheck-macros-1.0.0
                                         rust-quick-xml-0.37.5
                                         rust-quote-1.0.45
                                         rust-r-efi-5.3.0
                                         rust-r-efi-6.0.0
                                         rust-radicle-0.22.1
                                         rust-radicle-cob-0.19.0
                                         rust-radicle-core-0.2.0
                                         rust-radicle-crypto-0.16.0
                                         rust-radicle-dag-0.10.0
                                         rust-radicle-git-ext-0.12.0
                                         rust-radicle-git-metadata-0.1.0
                                         rust-radicle-git-metadata-0.2.0
                                         rust-radicle-git-ref-format-0.1.0
                                         rust-radicle-job-0.5.2
                                         rust-radicle-localtime-0.1.0
                                         rust-radicle-oid-0.1.0
                                         rust-radicle-ssh-0.10.0
                                         rust-radicle-std-ext-0.2.0
                                         rust-radicle-surf-0.27.0
                                         rust-rand-0.8.5
                                         rust-rand-chacha-0.3.1
                                         rust-rand-core-0.6.4
                                         rust-redox-syscall-0.7.3
                                         rust-ref-cast-1.0.25
                                         rust-ref-cast-impl-1.0.25
                                         rust-regex-1.12.3
                                         rust-regex-automata-0.4.14
                                         rust-regex-syntax-0.8.10
                                         rust-remove-dir-all-1.0.0
                                         rust-rfc6979-0.4.0
                                         rust-roadmap-0.7.0
                                         rust-rsa-0.9.10
                                         rust-rss-2.0.12
                                         rust-rust-decimal-1.40.0
                                         rust-rustix-1.1.4
                                         rust-rustversion-1.0.22
                                         rust-ryu-1.0.23
                                         rust-same-file-1.0.6
                                         rust-schemars-1.2.1
                                         rust-schemars-derive-1.2.1
                                         rust-scoped-tls-1.0.1
                                         rust-sec1-0.7.3
                                         rust-semver-1.0.27
                                         rust-serde-1.0.228
                                         rust-serde-untagged-0.1.9
                                         rust-serde-core-1.0.228
                                         rust-serde-derive-1.0.228
                                         rust-serde-derive-internals-0.29.1
                                         rust-serde-json-1.0.149
                                         rust-serde-norway-0.9.42
                                         rust-serde-path-to-error-0.1.20
                                         rust-sha2-0.10.9
                                         rust-sha3-0.10.8
                                         rust-sharded-slab-0.1.7
                                         rust-shell-words-1.1.1
                                         rust-shlex-1.3.0
                                         rust-signature-1.6.4
                                         rust-signature-2.2.0
                                         rust-simd-adler32-0.3.8
                                         rust-siphasher-1.0.2
                                         rust-slug-0.1.6
                                         rust-smallvec-1.15.1
                                         rust-smawk-0.3.2
                                         rust-socks5-client-0.4.1
                                         rust-spin-0.9.8
                                         rust-spki-0.7.3
                                         rust-sqlite-0.37.0
                                         rust-sqlite3-src-0.7.0
                                         rust-sqlite3-sys-0.18.0
                                         rust-ssh-cipher-0.2.0
                                         rust-ssh-encoding-0.2.0
                                         rust-ssh-key-0.6.7
                                         rust-stable-deref-trait-1.2.1
                                         rust-state-0.6.0
                                         rust-strsim-0.11.1
                                         rust-subplot-0.14.0
                                         rust-subplotlib-0.14.0
                                         rust-subplotlib-derive-0.14.0
                                         rust-subtle-2.6.1
                                         rust-syn-1.0.109
                                         rust-syn-2.0.117
                                         rust-sync-ptr-0.1.4
                                         rust-synstructure-0.13.2
                                         rust-tar-0.4.45
                                         rust-tempfile-3.27.0
                                         rust-tera-1.20.1
                                         rust-terminal-size-0.4.3
                                         rust-textwrap-0.16.2
                                         rust-thiserror-1.0.69
                                         rust-thiserror-2.0.18
                                         rust-thiserror-impl-1.0.69
                                         rust-thiserror-impl-2.0.18
                                         rust-thread-local-1.1.9
                                         rust-time-0.3.47
                                         rust-time-core-0.1.8
                                         rust-time-macros-0.2.27
                                         rust-tinystr-0.8.2
                                         rust-tinyvec-1.11.0
                                         rust-tinyvec-macros-0.1.1
                                         rust-tracing-0.1.44
                                         rust-tracing-attributes-0.1.31
                                         rust-tracing-core-0.1.36
                                         rust-tracing-log-0.2.0
                                         rust-tracing-serde-0.2.0
                                         rust-tracing-subscriber-0.3.23
                                         rust-typeid-1.0.3
                                         rust-typenum-1.19.0
                                         rust-ucd-trie-0.1.7
                                         rust-uds-windows-1.2.1
                                         rust-unicase-2.9.0
                                         rust-unicode-ident-1.0.24
                                         rust-unicode-linebreak-0.1.5
                                         rust-unicode-normalization-0.1.25
                                         rust-unicode-segmentation-1.12.0
                                         rust-unicode-width-0.2.2
                                         rust-unicode-xid-0.2.6
                                         rust-universal-hash-0.5.1
                                         rust-unsafe-libyaml-norway-0.2.15
                                         rust-url-2.5.8
                                         rust-utf8-width-0.1.8
                                         rust-utf8-iter-1.0.4
                                         rust-utf8parse-0.2.2
                                         rust-uuid-1.22.0
                                         rust-valuable-0.1.1
                                         rust-valuable-serde-0.1.1
                                         rust-vcpkg-0.2.15
                                         rust-version-check-0.9.5
                                         rust-walkdir-2.5.0
                                         rust-wasi-0.11.1+wasi-snapshot-preview1
                                         rust-wasip2-1.0.2+wasi-0.2.9
                                         rust-wasip3-0.4.0+wasi-0.3.0-rc-2026-01-06
                                         rust-wasm-bindgen-0.2.114
                                         rust-wasm-bindgen-macro-0.2.114
                                         rust-wasm-bindgen-macro-support-0.2.114
                                         rust-wasm-bindgen-shared-0.2.114
                                         rust-wasm-encoder-0.244.0
                                         rust-wasm-metadata-0.244.0
                                         rust-wasmparser-0.244.0
                                         rust-winapi-0.3.9
                                         rust-winapi-i686-pc-windows-gnu-0.4.0
                                         rust-winapi-util-0.1.11
                                         rust-winapi-x86-64-pc-windows-gnu-0.4.0
                                         rust-windows-0.48.0
                                         rust-windows-0.58.0
                                         rust-windows-core-0.58.0
                                         rust-windows-implement-0.58.0
                                         rust-windows-interface-0.58.0
                                         rust-windows-link-0.2.1
                                         rust-windows-result-0.2.0
                                         rust-windows-strings-0.1.0
                                         rust-windows-sys-0.52.0
                                         rust-windows-sys-0.59.0
                                         rust-windows-sys-0.60.2
                                         rust-windows-sys-0.61.2
                                         rust-windows-targets-0.48.5
                                         rust-windows-targets-0.52.6
                                         rust-windows-targets-0.53.5
                                         rust-windows-aarch64-gnullvm-0.48.5
                                         rust-windows-aarch64-gnullvm-0.52.6
                                         rust-windows-aarch64-gnullvm-0.53.1
                                         rust-windows-aarch64-msvc-0.48.5
                                         rust-windows-aarch64-msvc-0.52.6
                                         rust-windows-aarch64-msvc-0.53.1
                                         rust-windows-i686-gnu-0.48.5
                                         rust-windows-i686-gnu-0.52.6
                                         rust-windows-i686-gnu-0.53.1
                                         rust-windows-i686-gnullvm-0.52.6
                                         rust-windows-i686-gnullvm-0.53.1
                                         rust-windows-i686-msvc-0.48.5
                                         rust-windows-i686-msvc-0.52.6
                                         rust-windows-i686-msvc-0.53.1
                                         rust-windows-x86-64-gnu-0.48.5
                                         rust-windows-x86-64-gnu-0.52.6
                                         rust-windows-x86-64-gnu-0.53.1
                                         rust-windows-x86-64-gnullvm-0.48.5
                                         rust-windows-x86-64-gnullvm-0.52.6
                                         rust-windows-x86-64-gnullvm-0.53.1
                                         rust-windows-x86-64-msvc-0.48.5
                                         rust-windows-x86-64-msvc-0.52.6
                                         rust-windows-x86-64-msvc-0.53.1
                                         rust-winnow-0.7.15
                                         rust-winpipe-0.1.1
                                         rust-wit-bindgen-0.51.0
                                         rust-wit-bindgen-core-0.51.0
                                         rust-wit-bindgen-rust-0.51.0
                                         rust-wit-bindgen-rust-macro-0.51.0
                                         rust-wit-component-0.244.0
                                         rust-wit-parser-0.244.0
                                         rust-writeable-0.6.2
                                         rust-xattr-1.6.1
                                         rust-yaml-rust2-0.9.0
                                         rust-yaml-rust2-0.10.4
                                         rust-yoke-0.8.1
                                         rust-yoke-derive-0.8.1
                                         rust-zerocopy-0.8.47
                                         rust-zerocopy-derive-0.8.47
                                         rust-zerofrom-0.1.6
                                         rust-zerofrom-derive-0.1.6
                                         rust-zeroize-1.8.2
                                         rust-zerotrie-0.2.3
                                         rust-zerovec-0.11.5
                                         rust-zerovec-derive-0.11.2
                                         rust-zmij-1.0.21))
                     (radicle-http-api =>
                                       (list rust-addr2line-0.24.2
                                        rust-adler2-2.0.0
                                        rust-aead-0.5.2
                                        rust-aes-0.8.4
                                        rust-aes-gcm-0.10.3
                                        rust-aho-corasick-1.1.3
                                        rust-allocator-api2-0.2.18
                                        rust-amplify-4.7.0
                                        rust-amplify-derive-4.0.1
                                        rust-amplify-num-0.5.3
                                        rust-amplify-syn-2.0.1
                                        rust-android-tzdata-0.1.1
                                        rust-android-system-properties-0.1.5
                                        rust-anstyle-query-1.1.1
                                        rust-anyhow-1.0.89
                                        rust-ascii-1.1.0
                                        rust-async-trait-0.1.83
                                        rust-atomic-waker-1.1.2
                                        rust-autocfg-1.4.0
                                        rust-axum-0.7.7
                                        rust-axum-auth-0.7.0
                                        rust-axum-core-0.4.5
                                        rust-axum-server-0.7.1
                                        rust-backtrace-0.3.74
                                        rust-base-x-0.2.11
                                        rust-base16ct-0.2.0
                                        rust-base32-0.4.0
                                        rust-base64-0.21.7
                                        rust-base64-0.22.1
                                        rust-base64ct-1.6.0
                                        rust-bcrypt-pbkdf-0.10.0
                                        rust-bitflags-1.3.2
                                        rust-bitflags-2.6.0
                                        rust-block-buffer-0.10.4
                                        rust-block-padding-0.3.3
                                        rust-blowfish-0.9.1
                                        rust-bumpalo-3.16.0
                                        rust-byteorder-1.5.0
                                        rust-bytes-1.7.2
                                        rust-cbc-0.1.2
                                        rust-cc-1.1.30
                                        rust-cfg-if-1.0.0
                                        rust-chacha20-0.9.1
                                        rust-chrono-0.4.38
                                        rust-cipher-0.4.4
                                        rust-const-oid-0.9.6
                                        rust-core-foundation-sys-0.8.7
                                        rust-cpufeatures-0.2.14
                                        rust-crc32fast-1.4.2
                                        rust-crossbeam-channel-0.5.13
                                        rust-crossbeam-utils-0.8.20
                                        rust-crypto-bigint-0.5.5
                                        rust-crypto-common-0.1.6
                                        rust-ct-codecs-1.1.2
                                        rust-ctr-0.9.2
                                        rust-cypheraddr-0.4.0
                                        rust-cyphergraphy-0.3.0
                                        rust-cyphernet-0.5.2
                                        rust-data-encoding-2.6.0
                                        rust-data-encoding-macro-0.1.15
                                        rust-data-encoding-macro-internal-0.1.13
                                        rust-der-0.7.9
                                        rust-deranged-0.3.11
                                        rust-diff-0.1.13
                                        rust-digest-0.10.7
                                        rust-dyn-clone-1.0.17
                                        rust-ec25519-0.1.0
                                        rust-ecdsa-0.16.9
                                        rust-ed25519-1.5.3
                                        rust-elliptic-curve-0.13.8
                                        rust-equivalent-1.0.1
                                        rust-errno-0.3.9
                                        rust-fastrand-2.1.1
                                        rust-ff-0.13.0
                                        rust-filetime-0.2.25
                                        rust-flate2-1.0.34
                                        rust-fnv-1.0.7
                                        rust-foldhash-0.1.3
                                        rust-form-urlencoded-1.2.1
                                        rust-futures-channel-0.3.31
                                        rust-futures-core-0.3.31
                                        rust-futures-sink-0.3.31
                                        rust-futures-task-0.3.31
                                        rust-futures-util-0.3.31
                                        rust-fxhash-0.2.1
                                        rust-generic-array-0.14.7
                                        rust-getrandom-0.2.15
                                        rust-ghash-0.5.1
                                        rust-gimli-0.31.1
                                        rust-git-ref-format-0.3.1
                                        rust-git-ref-format-core-0.3.1
                                        rust-git-ref-format-macro-0.3.1
                                        rust-git2-0.19.0
                                        rust-group-0.13.0
                                        rust-h2-0.4.6
                                        rust-hashbrown-0.15.0
                                        rust-hermit-abi-0.3.9
                                        rust-hmac-0.12.1
                                        rust-http-1.1.0
                                        rust-http-body-1.0.1
                                        rust-http-body-util-0.1.2
                                        rust-httparse-1.9.5
                                        rust-httpdate-1.0.3
                                        rust-hyper-1.5.0
                                        rust-hyper-util-0.1.9
                                        rust-iana-time-zone-0.1.61
                                        rust-iana-time-zone-haiku-0.1.2
                                        rust-idna-0.5.0
                                        rust-indexmap-2.6.0
                                        rust-inout-0.1.3
                                        rust-inquire-0.7.5
                                        rust-itoa-1.0.11
                                        rust-jobserver-0.1.32
                                        rust-js-sys-0.3.72
                                        rust-keccak-0.1.5
                                        rust-lazy-static-1.5.0
                                        rust-lexopt-0.3.0
                                        rust-libc-0.2.160
                                        rust-libgit2-sys-0.17.0+1.8.1
                                        rust-libm-0.2.8
                                        rust-libredox-0.0.2
                                        rust-libredox-0.1.3
                                        rust-libz-sys-1.1.20
                                        rust-linux-raw-sys-0.4.14
                                        rust-localtime-1.3.1
                                        rust-log-0.4.22
                                        rust-lru-0.12.5
                                        rust-matchers-0.1.0
                                        rust-matchit-0.7.3
                                        rust-memchr-2.7.4
                                        rust-mime-0.3.17
                                        rust-miniz-oxide-0.8.0
                                        rust-mio-1.0.2
                                        rust-multibase-0.9.1
                                        rust-newline-converter-0.3.0
                                        rust-nonempty-0.9.0
                                        rust-nu-ansi-term-0.46.0
                                        rust-num-bigint-dig-0.8.4
                                        rust-num-conv-0.1.0
                                        rust-num-integer-0.1.46
                                        rust-num-iter-0.1.45
                                        rust-num-traits-0.2.19
                                        rust-numtoa-0.1.0
                                        rust-object-0.36.5
                                        rust-once-cell-1.20.2
                                        rust-opaque-debug-0.3.1
                                        rust-overload-0.1.1
                                        rust-p256-0.13.2
                                        rust-p384-0.13.0
                                        rust-p521-0.13.3
                                        rust-pbkdf2-0.12.2
                                        rust-pem-rfc7468-0.7.0
                                        rust-percent-encoding-2.3.1
                                        rust-pin-project-1.1.6
                                        rust-pin-project-internal-1.1.6
                                        rust-pin-project-lite-0.2.14
                                        rust-pin-utils-0.1.0
                                        rust-pkcs1-0.7.5
                                        rust-pkcs8-0.10.2
                                        rust-pkg-config-0.3.31
                                        rust-poly1305-0.8.0
                                        rust-polyval-0.6.2
                                        rust-powerfmt-0.2.0
                                        rust-ppv-lite86-0.2.20
                                        rust-pretty-assertions-1.4.1
                                        rust-primeorder-0.13.6
                                        rust-proc-macro-error-1.0.4
                                        rust-proc-macro-error-attr-1.0.4
                                        rust-proc-macro2-1.0.88
                                        rust-qcheck-1.0.0
                                        rust-quote-1.0.37
                                        rust-radicle-0.13.0
                                        rust-radicle-cob-0.12.0
                                        rust-radicle-crypto-0.11.0
                                        rust-radicle-dag-0.9.0
                                        rust-radicle-git-ext-0.8.1
                                        rust-radicle-signals-0.10.0
                                        rust-radicle-ssh-0.9.0
                                        rust-radicle-std-ext-0.1.0
                                        rust-radicle-surf-0.22.1
                                        rust-radicle-term-0.11.0
                                        rust-rand-0.8.5
                                        rust-rand-chacha-0.3.1
                                        rust-rand-core-0.6.4
                                        rust-redox-syscall-0.4.1
                                        rust-redox-syscall-0.5.7
                                        rust-redox-termios-0.1.3
                                        rust-regex-1.11.0
                                        rust-regex-automata-0.1.10
                                        rust-regex-automata-0.4.8
                                        rust-regex-syntax-0.6.29
                                        rust-regex-syntax-0.8.5
                                        rust-rfc6979-0.4.0
                                        rust-rsa-0.9.6
                                        rust-rustc-demangle-0.1.24
                                        rust-rustix-0.38.37
                                        rust-rustversion-1.0.18
                                        rust-ryu-1.0.18
                                        rust-sec1-0.7.3
                                        rust-serde-1.0.210
                                        rust-serde-derive-1.0.210
                                        rust-serde-json-1.0.128
                                        rust-serde-path-to-error-0.1.16
                                        rust-serde-urlencoded-0.7.1
                                        rust-sha2-0.10.8
                                        rust-sha3-0.10.8
                                        rust-sharded-slab-0.1.7
                                        rust-shlex-1.3.0
                                        rust-signature-1.6.4
                                        rust-signature-2.2.0
                                        rust-siphasher-1.0.1
                                        rust-slab-0.4.9
                                        rust-smallvec-1.13.2
                                        rust-socket2-0.5.7
                                        rust-socks5-client-0.4.1
                                        rust-spin-0.9.8
                                        rust-spki-0.7.3
                                        rust-sqlite-0.32.0
                                        rust-sqlite3-src-0.5.1
                                        rust-sqlite3-sys-0.15.2
                                        rust-ssh-cipher-0.2.0
                                        rust-ssh-encoding-0.2.0
                                        rust-ssh-key-0.6.7
                                        rust-subtle-2.6.1
                                        rust-syn-1.0.109
                                        rust-syn-2.0.79
                                        rust-sync-wrapper-0.1.2
                                        rust-sync-wrapper-1.0.1
                                        rust-tar-0.4.42
                                        rust-tempfile-3.13.0
                                        rust-termion-2.0.3
                                        rust-termion-3.0.0
                                        rust-thiserror-1.0.64
                                        rust-thiserror-impl-1.0.64
                                        rust-thread-local-1.1.8
                                        rust-time-0.3.36
                                        rust-time-core-0.1.2
                                        rust-time-macros-0.2.18
                                        rust-tinyvec-1.8.0
                                        rust-tinyvec-macros-0.1.1
                                        rust-tokio-1.40.0
                                        rust-tokio-macros-2.4.0
                                        rust-tokio-util-0.7.12
                                        rust-tower-0.4.13
                                        rust-tower-0.5.1
                                        rust-tower-http-0.6.1
                                        rust-tower-layer-0.3.3
                                        rust-tower-service-0.3.3
                                        rust-tracing-0.1.40
                                        rust-tracing-attributes-0.1.27
                                        rust-tracing-core-0.1.32
                                        rust-tracing-logfmt-0.3.5
                                        rust-tracing-subscriber-0.3.18
                                        rust-try-lock-0.2.5
                                        rust-typenum-1.17.0
                                        rust-unicode-bidi-0.3.17
                                        rust-unicode-display-width-0.3.0
                                        rust-unicode-ident-1.0.13
                                        rust-unicode-normalization-0.1.24
                                        rust-unicode-segmentation-1.12.0
                                        rust-unicode-width-0.1.14
                                        rust-universal-hash-0.5.1
                                        rust-ureq-2.10.1
                                        rust-url-2.5.2
                                        rust-valuable-0.1.0
                                        rust-vcpkg-0.2.15
                                        rust-version-check-0.9.5
                                        rust-want-0.3.1
                                        rust-wasi-0.11.0+wasi-snapshot-preview1
                                        rust-wasm-bindgen-0.2.95
                                        rust-wasm-bindgen-backend-0.2.95
                                        rust-wasm-bindgen-macro-0.2.95
                                        rust-wasm-bindgen-macro-support-0.2.95
                                        rust-wasm-bindgen-shared-0.2.95
                                        rust-winapi-0.3.9
                                        rust-winapi-i686-pc-windows-gnu-0.4.0
                                        rust-winapi-x86-64-pc-windows-gnu-0.4.0
                                        rust-windows-core-0.52.0
                                        rust-windows-sys-0.52.0
                                        rust-windows-sys-0.59.0
                                        rust-windows-targets-0.52.6
                                        rust-windows-aarch64-gnullvm-0.52.6
                                        rust-windows-aarch64-msvc-0.52.6
                                        rust-windows-i686-gnu-0.52.6
                                        rust-windows-i686-gnullvm-0.52.6
                                        rust-windows-i686-msvc-0.52.6
                                        rust-windows-x86-64-gnu-0.52.6
                                        rust-windows-x86-64-gnullvm-0.52.6
                                        rust-windows-x86-64-msvc-0.52.6
                                        rust-xattr-1.3.1
                                        rust-yansi-1.0.1
                                        rust-zerocopy-0.7.35
                                        rust-zerocopy-derive-0.7.35
                                        rust-zeroize-1.8.1))
                     (radicle-native-ci =>
                                        (list rust-adler2-2.0.1
                                         rust-aead-0.5.2
                                         rust-aes-0.8.4
                                         rust-aes-gcm-0.10.3
                                         rust-ahash-0.8.12
                                         rust-aho-corasick-1.1.4
                                         rust-aligned-0.4.3
                                         rust-amplify-4.9.0
                                         rust-amplify-derive-4.0.1
                                         rust-amplify-num-0.5.3
                                         rust-amplify-syn-2.0.1
                                         rust-anstream-1.0.0
                                         rust-anstyle-1.0.14
                                         rust-anstyle-parse-1.0.0
                                         rust-anstyle-query-1.1.5
                                         rust-anstyle-wincon-3.0.11
                                         rust-anyhow-1.0.102
                                         rust-arraydeque-0.5.1
                                         rust-arrayvec-0.7.6
                                         rust-as-slice-0.2.1
                                         rust-ascii-1.1.0
                                         rust-atom-syndication-0.12.7
                                         rust-autocfg-1.5.0
                                         rust-base-x-0.2.11
                                         rust-base16ct-0.2.0
                                         rust-base256emoji-1.0.2
                                         rust-base32-0.4.0
                                         rust-base64-0.21.7
                                         rust-base64-0.22.1
                                         rust-base64ct-1.8.3
                                         rust-bcrypt-pbkdf-0.10.0
                                         rust-bitflags-2.11.0
                                         rust-block-buffer-0.10.4
                                         rust-block-padding-0.3.3
                                         rust-blowfish-0.9.1
                                         rust-bstr-1.12.1
                                         rust-bumpalo-3.20.2
                                         rust-byteorder-1.5.0
                                         rust-bytesize-2.3.1
                                         rust-cbc-0.1.2
                                         rust-cc-1.2.57
                                         rust-cfg-if-1.0.4
                                         rust-cfg-aliases-0.2.1
                                         rust-chacha20-0.9.1
                                         rust-chrono-0.4.44
                                         rust-cipher-0.4.4
                                         rust-clap-4.6.0
                                         rust-clap-builder-4.6.0
                                         rust-clap-derive-4.6.0
                                         rust-clap-lex-1.1.0
                                         rust-colorchoice-1.0.5
                                         rust-const-oid-0.9.6
                                         rust-const-str-0.4.3
                                         rust-cpufeatures-0.2.17
                                         rust-crc32fast-1.5.0
                                         rust-crossbeam-channel-0.5.15
                                         rust-crossbeam-deque-0.8.6
                                         rust-crossbeam-epoch-0.9.18
                                         rust-crossbeam-utils-0.8.21
                                         rust-crypto-bigint-0.5.5
                                         rust-crypto-common-0.1.7
                                         rust-ct-codecs-1.1.6
                                         rust-ctr-0.9.2
                                         rust-culpa-1.0.2
                                         rust-culpa-macros-1.0.2
                                         rust-cvt-0.1.2
                                         rust-cypheraddr-0.4.0
                                         rust-cyphergraphy-0.3.0
                                         rust-cyphernet-0.5.2
                                         rust-darling-0.20.11
                                         rust-darling-core-0.20.11
                                         rust-darling-macro-0.20.11
                                         rust-data-encoding-2.10.0
                                         rust-data-encoding-macro-0.1.19
                                         rust-data-encoding-macro-internal-0.1.17
                                         rust-defer-heavy-0.1.0
                                         rust-der-0.7.10
                                         rust-deranged-0.5.8
                                         rust-derive-builder-0.20.2
                                         rust-derive-builder-core-0.20.2
                                         rust-derive-builder-macro-0.20.2
                                         rust-descape-3.0.0
                                         rust-deunicode-1.6.2
                                         rust-digest-0.10.7
                                         rust-diligent-date-parser-0.1.5
                                         rust-displaydoc-0.2.5
                                         rust-doc-comment-0.3.4
                                         rust-dunce-1.0.5
                                         rust-duration-str-0.21.0
                                         rust-dyn-clone-1.0.20
                                         rust-ec25519-0.1.0
                                         rust-ecdsa-0.16.9
                                         rust-ed25519-1.5.3
                                         rust-elliptic-curve-0.13.8
                                         rust-encoding-rs-0.8.35
                                         rust-equivalent-1.0.2
                                         rust-erased-serde-0.4.10
                                         rust-errno-0.3.14
                                         rust-fast-glob-0.3.3
                                         rust-fastrand-2.3.0
                                         rust-ff-0.13.1
                                         rust-filetime-0.2.27
                                         rust-find-msvc-tools-0.1.9
                                         rust-flate2-1.1.9
                                         rust-fnv-1.0.7
                                         rust-foldhash-0.1.5
                                         rust-form-urlencoded-1.2.2
                                         rust-fs2-0.4.3
                                         rust-fs-at-0.2.1
                                         rust-generator-0.7.5
                                         rust-generic-array-0.14.7
                                         rust-getopts-0.2.24
                                         rust-getrandom-0.2.17
                                         rust-getrandom-0.3.4
                                         rust-getrandom-0.4.2
                                         rust-ghash-0.5.1
                                         rust-git-ref-format-0.6.0
                                         rust-git-ref-format-core-0.6.0
                                         rust-git-ref-format-macro-0.6.0
                                         rust-git2-0.20.4
                                         rust-globset-0.4.18
                                         rust-globwalk-0.9.1
                                         rust-group-0.13.0
                                         rust-hashbrown-0.14.5
                                         rust-hashbrown-0.15.5
                                         rust-hashbrown-0.16.1
                                         rust-hashlink-0.9.1
                                         rust-hashlink-0.10.0
                                         rust-heck-0.5.0
                                         rust-hmac-0.12.1
                                         rust-html-escape-0.2.13
                                         rust-html-page-0.5.0
                                         rust-humansize-2.1.3
                                         rust-icu-collections-2.1.1
                                         rust-icu-locale-core-2.1.1
                                         rust-icu-normalizer-2.1.1
                                         rust-icu-normalizer-data-2.1.1
                                         rust-icu-properties-2.1.2
                                         rust-icu-properties-data-2.1.2
                                         rust-icu-provider-2.1.1
                                         rust-id-arena-2.3.0
                                         rust-ident-case-1.0.1
                                         rust-idna-1.1.0
                                         rust-idna-adapter-1.2.1
                                         rust-ignore-0.4.25
                                         rust-indexmap-2.13.0
                                         rust-inout-0.1.4
                                         rust-is-terminal-polyfill-1.70.2
                                         rust-itoa-1.0.18
                                         rust-jobserver-0.1.34
                                         rust-js-sys-0.3.91
                                         rust-keccak-0.1.6
                                         rust-lazy-static-1.5.0
                                         rust-leb128fmt-0.1.0
                                         rust-libc-0.2.183
                                         rust-libgit2-sys-0.18.3+1.9.2
                                         rust-libm-0.2.16
                                         rust-libredox-0.1.14
                                         rust-libz-sys-1.1.25
                                         rust-line-col-0.2.1
                                         rust-linux-raw-sys-0.12.1
                                         rust-litemap-0.8.1
                                         rust-log-0.4.29
                                         rust-loom-0.5.6
                                         rust-marked-yaml-0.7.2
                                         rust-marked-yaml-0.8.0
                                         rust-match-lookup-0.1.2
                                         rust-matchers-0.2.0
                                         rust-memchr-2.8.0
                                         rust-memoffset-0.9.1
                                         rust-miniz-oxide-0.8.9
                                         rust-multibase-0.9.2
                                         rust-never-0.1.0
                                         rust-nix-0.29.0
                                         rust-nonempty-0.9.0
                                         rust-nonempty-0.11.0
                                         rust-nonempty-0.12.0
                                         rust-normpath-1.5.0
                                         rust-nu-ansi-term-0.50.3
                                         rust-num-bigint-dig-0.8.6
                                         rust-num-conv-0.2.0
                                         rust-num-integer-0.1.46
                                         rust-num-iter-0.1.45
                                         rust-num-traits-0.2.19
                                         rust-once-cell-1.21.4
                                         rust-once-cell-polyfill-1.70.2
                                         rust-opaque-debug-0.3.1
                                         rust-p256-0.13.2
                                         rust-p384-0.13.1
                                         rust-p521-0.13.3
                                         rust-pbkdf2-0.12.2
                                         rust-pem-rfc7468-0.7.0
                                         rust-percent-encoding-2.3.2
                                         rust-pest-2.8.6
                                         rust-pest-derive-2.8.6
                                         rust-pest-generator-2.8.6
                                         rust-pest-meta-2.8.6
                                         rust-pikchr-0.1.4
                                         rust-pin-project-lite-0.2.17
                                         rust-pkcs1-0.7.5
                                         rust-pkcs8-0.10.2
                                         rust-pkg-config-0.3.32
                                         rust-plain-0.2.3
                                         rust-poly1305-0.8.0
                                         rust-polyval-0.6.2
                                         rust-potential-utf-0.1.4
                                         rust-powerfmt-0.2.0
                                         rust-ppv-lite86-0.2.21
                                         rust-prettyplease-0.2.37
                                         rust-primeorder-0.13.6
                                         rust-proc-macro-error-attr2-2.0.0
                                         rust-proc-macro-error2-2.0.1
                                         rust-proc-macro2-1.0.106
                                         rust-pulldown-cmark-0.13.3
                                         rust-pulldown-cmark-escape-0.11.0
                                         rust-qcheck-1.0.0
                                         rust-quick-xml-0.37.5
                                         rust-quote-1.0.45
                                         rust-r-efi-5.3.0
                                         rust-r-efi-6.0.0
                                         rust-radicle-0.22.1
                                         rust-radicle-ci-broker-0.27.0
                                         rust-radicle-cob-0.19.0
                                         rust-radicle-core-0.2.0
                                         rust-radicle-crypto-0.16.0
                                         rust-radicle-dag-0.10.0
                                         rust-radicle-git-ext-0.12.0
                                         rust-radicle-git-metadata-0.1.0
                                         rust-radicle-git-metadata-0.2.0
                                         rust-radicle-git-ref-format-0.1.0
                                         rust-radicle-job-0.5.2
                                         rust-radicle-localtime-0.1.0
                                         rust-radicle-oid-0.1.0
                                         rust-radicle-ssh-0.10.0
                                         rust-radicle-std-ext-0.2.0
                                         rust-radicle-surf-0.27.0
                                         rust-rand-0.8.5
                                         rust-rand-chacha-0.3.1
                                         rust-rand-core-0.6.4
                                         rust-redox-syscall-0.7.3
                                         rust-ref-cast-1.0.25
                                         rust-ref-cast-impl-1.0.25
                                         rust-regex-1.12.3
                                         rust-regex-automata-0.4.14
                                         rust-regex-syntax-0.8.10
                                         rust-remove-dir-all-1.0.0
                                         rust-rfc6979-0.4.0
                                         rust-roadmap-0.7.0
                                         rust-rsa-0.9.10
                                         rust-rss-2.0.12
                                         rust-rust-decimal-1.40.0
                                         rust-rustix-1.1.4
                                         rust-rustversion-1.0.22
                                         rust-ryu-1.0.23
                                         rust-same-file-1.0.6
                                         rust-schemars-1.2.1
                                         rust-schemars-derive-1.2.1
                                         rust-scoped-tls-1.0.1
                                         rust-sec1-0.7.3
                                         rust-semver-1.0.27
                                         rust-serde-1.0.228
                                         rust-serde-untagged-0.1.9
                                         rust-serde-core-1.0.228
                                         rust-serde-derive-1.0.228
                                         rust-serde-derive-internals-0.29.1
                                         rust-serde-json-1.0.149
                                         rust-serde-norway-0.9.42
                                         rust-serde-path-to-error-0.1.20
                                         rust-sha2-0.10.9
                                         rust-sha3-0.10.8
                                         rust-sharded-slab-0.1.7
                                         rust-shell-words-1.1.1
                                         rust-shlex-1.3.0
                                         rust-signature-1.6.4
                                         rust-signature-2.2.0
                                         rust-simd-adler32-0.3.8
                                         rust-siphasher-1.0.2
                                         rust-slug-0.1.6
                                         rust-smallvec-1.15.1
                                         rust-smawk-0.3.2
                                         rust-socks5-client-0.4.1
                                         rust-spin-0.9.8
                                         rust-spki-0.7.3
                                         rust-sqlite-0.37.0
                                         rust-sqlite3-src-0.7.0
                                         rust-sqlite3-sys-0.18.0
                                         rust-ssh-cipher-0.2.0
                                         rust-ssh-encoding-0.2.0
                                         rust-ssh-key-0.6.7
                                         rust-stable-deref-trait-1.2.1
                                         rust-state-0.6.0
                                         rust-strsim-0.11.1
                                         rust-subplot-0.14.0
                                         rust-subplotlib-0.14.0
                                         rust-subplotlib-derive-0.14.0
                                         rust-subtle-2.6.1
                                         rust-syn-1.0.109
                                         rust-syn-2.0.117
                                         rust-sync-ptr-0.1.4
                                         rust-synstructure-0.13.2
                                         rust-tar-0.4.45
                                         rust-tempfile-3.27.0
                                         rust-tera-1.20.1
                                         rust-terminal-size-0.4.4
                                         rust-textwrap-0.16.2
                                         rust-thiserror-1.0.69
                                         rust-thiserror-2.0.18
                                         rust-thiserror-impl-1.0.69
                                         rust-thiserror-impl-2.0.18
                                         rust-thread-local-1.1.9
                                         rust-time-0.3.47
                                         rust-time-core-0.1.8
                                         rust-time-macros-0.2.27
                                         rust-tinystr-0.8.2
                                         rust-tinyvec-1.11.0
                                         rust-tinyvec-macros-0.1.1
                                         rust-tracing-0.1.44
                                         rust-tracing-attributes-0.1.31
                                         rust-tracing-core-0.1.36
                                         rust-tracing-log-0.2.0
                                         rust-tracing-serde-0.2.0
                                         rust-tracing-subscriber-0.3.23
                                         rust-typeid-1.0.3
                                         rust-typenum-1.19.0
                                         rust-ucd-trie-0.1.7
                                         rust-uds-windows-1.2.1
                                         rust-unicase-2.9.0
                                         rust-unicode-ident-1.0.24
                                         rust-unicode-linebreak-0.1.5
                                         rust-unicode-normalization-0.1.25
                                         rust-unicode-segmentation-1.12.0
                                         rust-unicode-width-0.2.2
                                         rust-unicode-xid-0.2.6
                                         rust-universal-hash-0.5.1
                                         rust-unsafe-libyaml-norway-0.2.15
                                         rust-url-2.5.8
                                         rust-utf8-width-0.1.8
                                         rust-utf8-iter-1.0.4
                                         rust-utf8parse-0.2.2
                                         rust-uuid-1.22.0
                                         rust-valuable-0.1.1
                                         rust-valuable-serde-0.1.1
                                         rust-vcpkg-0.2.15
                                         rust-version-check-0.9.5
                                         rust-walkdir-2.5.0
                                         rust-wasi-0.11.1+wasi-snapshot-preview1
                                         rust-wasip2-1.0.2+wasi-0.2.9
                                         rust-wasip3-0.4.0+wasi-0.3.0-rc-2026-01-06
                                         rust-wasm-bindgen-0.2.114
                                         rust-wasm-bindgen-macro-0.2.114
                                         rust-wasm-bindgen-macro-support-0.2.114
                                         rust-wasm-bindgen-shared-0.2.114
                                         rust-wasm-encoder-0.244.0
                                         rust-wasm-metadata-0.244.0
                                         rust-wasmparser-0.244.0
                                         rust-winapi-0.3.9
                                         rust-winapi-i686-pc-windows-gnu-0.4.0
                                         rust-winapi-util-0.1.11
                                         rust-winapi-x86-64-pc-windows-gnu-0.4.0
                                         rust-windows-0.48.0
                                         rust-windows-0.58.0
                                         rust-windows-core-0.58.0
                                         rust-windows-implement-0.58.0
                                         rust-windows-interface-0.58.0
                                         rust-windows-link-0.2.1
                                         rust-windows-result-0.2.0
                                         rust-windows-strings-0.1.0
                                         rust-windows-sys-0.52.0
                                         rust-windows-sys-0.59.0
                                         rust-windows-sys-0.61.2
                                         rust-windows-targets-0.48.5
                                         rust-windows-targets-0.52.6
                                         rust-windows-aarch64-gnullvm-0.48.5
                                         rust-windows-aarch64-gnullvm-0.52.6
                                         rust-windows-aarch64-msvc-0.48.5
                                         rust-windows-aarch64-msvc-0.52.6
                                         rust-windows-i686-gnu-0.48.5
                                         rust-windows-i686-gnu-0.52.6
                                         rust-windows-i686-gnullvm-0.52.6
                                         rust-windows-i686-msvc-0.48.5
                                         rust-windows-i686-msvc-0.52.6
                                         rust-windows-x86-64-gnu-0.48.5
                                         rust-windows-x86-64-gnu-0.52.6
                                         rust-windows-x86-64-gnullvm-0.48.5
                                         rust-windows-x86-64-gnullvm-0.52.6
                                         rust-windows-x86-64-msvc-0.48.5
                                         rust-windows-x86-64-msvc-0.52.6
                                         rust-winnow-0.7.15
                                         rust-winpipe-0.1.1
                                         rust-wit-bindgen-0.51.0
                                         rust-wit-bindgen-core-0.51.0
                                         rust-wit-bindgen-rust-0.51.0
                                         rust-wit-bindgen-rust-macro-0.51.0
                                         rust-wit-component-0.244.0
                                         rust-wit-parser-0.244.0
                                         rust-writeable-0.6.2
                                         rust-xattr-1.6.1
                                         rust-yaml-rust2-0.9.0
                                         rust-yaml-rust2-0.10.4
                                         rust-yoke-0.8.1
                                         rust-yoke-derive-0.8.1
                                         rust-zerocopy-0.8.47
                                         rust-zerocopy-derive-0.8.47
                                         rust-zerofrom-0.1.6
                                         rust-zerofrom-derive-0.1.6
                                         rust-zeroize-1.8.2
                                         rust-zerotrie-0.2.3
                                         rust-zerovec-0.11.5
                                         rust-zerovec-derive-0.11.2
                                         rust-zmij-1.0.21))
                     (rns-bridge =>
                                 (list rust-aes-0.9.3
                                  rust-aho-corasick-1.1.4
                                  rust-anstream-1.0.0
                                  rust-anstyle-1.0.14
                                  rust-anstyle-parse-1.0.0
                                  rust-anstyle-query-1.1.5
                                  rust-anstyle-wincon-3.0.11
                                  rust-anyhow-1.0.102
                                  rust-bitflags-2.11.0
                                  rust-block-buffer-0.12.1
                                  rust-block-padding-0.4.2
                                  rust-bytes-1.11.1
                                  rust-bzip2-0.6.1
                                  rust-bzip2-sys-0.1.13+1.0.8
                                  rust-cbc-0.2.1
                                  rust-cc-1.2.60
                                  rust-cfg-if-1.0.4
                                  rust-cipher-0.5.2
                                  rust-clap-4.6.0
                                  rust-clap-builder-4.6.0
                                  rust-clap-derive-4.6.0
                                  rust-clap-lex-1.1.0
                                  rust-cmov-0.5.4
                                  rust-colorchoice-1.0.5
                                  rust-concurrent-queue-2.5.0
                                  rust-cpubits-0.1.1
                                  rust-cpufeatures-0.3.1
                                  rust-crossbeam-deque-0.8.6
                                  rust-crossbeam-epoch-0.9.18
                                  rust-crossbeam-utils-0.8.21
                                  rust-crypto-common-0.2.2
                                  rust-ctutils-0.4.2
                                  rust-curve25519-dalek-5.0.0
                                  rust-curve25519-dalek-derive-0.1.1
                                  rust-digest-0.11.3
                                  rust-ed25519-3.0.0
                                  rust-ed25519-dalek-3.0.0
                                  rust-either-1.15.0
                                  rust-env-filter-1.0.1
                                  rust-env-logger-0.11.10
                                  rust-errno-0.3.14
                                  rust-fiat-crypto-0.3.0
                                  rust-find-msvc-tools-0.1.9
                                  rust-futures-core-0.3.32
                                  rust-futures-sink-0.3.32
                                  rust-heck-0.5.0
                                  rust-hermit-abi-0.5.2
                                  rust-hex-0.4.3
                                  rust-hmac-0.13.0
                                  rust-hybrid-array-0.4.14
                                  rust-inout-0.2.2
                                  rust-is-terminal-polyfill-1.70.2
                                  rust-jiff-0.2.23
                                  rust-jiff-static-0.2.23
                                  rust-libc-0.2.184
                                  rust-libm-0.2.16
                                  rust-linux-raw-sys-0.12.1
                                  rust-lock-api-0.4.14
                                  rust-log-0.4.29
                                  rust-memchr-2.8.0
                                  rust-mio-1.2.0
                                  rust-once-cell-polyfill-1.70.2
                                  rust-parking-lot-0.12.5
                                  rust-parking-lot-core-0.9.12
                                  rust-pin-project-lite-0.2.17
                                  rust-pkg-config-0.3.32
                                  rust-polling-3.11.0
                                  rust-portable-atomic-1.13.1
                                  rust-portable-atomic-util-0.2.6
                                  rust-proc-macro2-1.0.106
                                  rust-quote-1.0.45
                                  rust-rand-core-0.10.1
                                  rust-rayon-1.11.0
                                  rust-rayon-core-1.13.0
                                  rust-redox-syscall-0.5.18
                                  rust-regex-1.12.3
                                  rust-regex-automata-0.4.14
                                  rust-regex-syntax-0.8.10
                                  rust-rns-core-0.1.17
                                  rust-rns-crypto-0.1.10
                                  rust-rns-net-0.7.1
                                  rust-rustc-version-0.4.1
                                  rust-rustix-1.1.4
                                  rust-scopeguard-1.2.0
                                  rust-semver-1.0.28
                                  rust-serde-core-1.0.228
                                  rust-serde-derive-1.0.228
                                  rust-sha2-0.11.0
                                  rust-shlex-1.3.0
                                  rust-signal-hook-registry-1.4.8
                                  rust-signature-3.0.0
                                  rust-smallvec-1.15.1
                                  rust-socket2-0.6.3
                                  rust-strsim-0.11.1
                                  rust-subtle-2.6.1
                                  rust-syn-2.0.117
                                  rust-tokio-1.51.1
                                  rust-tokio-macros-2.7.0
                                  rust-tokio-util-0.7.18
                                  rust-typenum-1.20.1
                                  rust-unicode-ident-1.0.24
                                  rust-utf8parse-0.2.2
                                  rust-wasi-0.11.1+wasi-snapshot-preview1
                                  rust-windows-link-0.2.1
                                  rust-windows-sys-0.61.2
                                  rust-x25519-dalek-3.0.0)))
