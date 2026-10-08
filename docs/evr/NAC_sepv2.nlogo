globals [
  current-time
  current-host
]

breed [members member]
undirected-link-breed [review-links review-link]

members-own [
  local-public-rep
  culcus
  bad-actor?
  true-aptitude
  true-disposition
  reviewed-aptitude
  reviewed-disposition
  opportunity-count
]

review-links-own [
  aptitude-score
  disposition-score
  age
]

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SETUP
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to setup
  clear-all
  set current-time 0
  ask patches [ set pcolor 3 ]  ; dark grey shade

  ;; Create members
  create-members 10 [
    set local-public-rep 50 + random starting-rep-variation
    set culcus 50
    set bad-actor? (random-float 1.0 < 0.2)
    set shape "circle"
    set size 1.5
    set true-aptitude random-normal 50 starting-aptitude-variation
    set true-disposition random-normal 50 starting-disp-variation
    set reviewed-aptitude 50
    set reviewed-disposition 50
    set label word "Rep: " word (round local-public-rep) word " | D: " word (round true-disposition) word " | A: " (round true-aptitude)

    let trait-color 0
    if layout-mode = "aptitude" [ set trait-color true-aptitude ]
    if layout-mode = "disposition" [ set trait-color true-disposition ]
    if layout-mode = "reputation" [ set trait-color local-public-rep ]

    set color scale-color blue trait-color 0 100

    set opportunity-count 0

  ]

  layout-by-mode
  reset-ticks
end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; MAIN LOOP
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to go
  simulate-opportunity
  pull-toward-review-partners
  decay-links
  decay-reputation
  update-visuals
  tick

  if ticks >= 150 [ stop ]
end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; OPPORTUNITY SIMULATION
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to simulate-opportunity
  let eligible-hosts members with [culcus >= 30]
  if any? eligible-hosts [
    let host one-of eligible-hosts
    set current-host host

    ;; Reputation-gated, A-based participation
    let candidates members with [self != host]
    let participants (turtle-set host)

   ask candidates [
      let my-a true-aptitude
      let host-a [reviewed-aptitude] of host
      let delta-a max (list (host-a - my-a) 0)
      let delta-weight 1 - 1 / (1 + delta-a)

      let avg-rep mean [local-public-rep] of members
      let rep-diff [local-public-rep] of host - avg-rep
      let rep-weight 1 / (1 + exp (-0.1 * rep-diff))

      let join-prob 0.2 + (rep-weight * delta-weight) ; 0.2 is base participation rate, regardless of reputation or delta-a

      if random-float 1.0 < join-prob [
        set participants (turtle-set participants self)
  ]
]


    ;; Only proceed if someone joins
    if count participants > 1 [
      ;; Reviews: everyone reviews everyone
      ask participants [
        let reviewer self
        ask other participants [
          let target self
          if reviewer != target [
            ;; Generate two scores with noise
            let d-score random-normal [true-disposition] of target 10
            let a-score random-normal [true-aptitude] of target 10
            post-review reviewer target a-score d-score
          ]
        ]
      ]

      ;; Reward host culcus
      ask host [ set culcus culcus + 1 ]
    ]
    ask participants [
  set opportunity-count opportunity-count + 1
]


    ;; Grow true-aptitude from participation
ask participants with [self != current-host] [
  let host-a [true-aptitude] of current-host
  let delta (host-a - true-aptitude)
  let gain base-growth
  if delta > 0 [
    set gain gain + (delta * delta-growth-multiplier)
  ]
  set true-aptitude min list 100 (true-aptitude + gain)
]


  ]


end


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; POST-REVIEW
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to post-review [reviewer target a-score d-score]
  ask target [
    let is-host (self = current-host)
    let weight-factor (ifelse-value is-host [host-review-weight] [1.0])

    ;; Update perception of target's aptitude (not used for rep)
    set reviewed-aptitude (0.9 * reviewed-aptitude) + (0.1 * a-score)

    ;; Update perception of disposition (used for rep)
    set reviewed-disposition (0.9 * reviewed-disposition) + (0.1 * d-score)

    let base-rep-gain participation-rep-bump
    let review-adjustment ((d-score - 50) / 100) * weight-factor
    let net-rep-gain base-rep-gain + review-adjustment
    set local-public-rep local-public-rep + net-rep-gain

  ]

  ask reviewer [
    ;; Remove existing link if one exists
    if review-link-neighbor? target [
      ask review-link-with target [ die ]
    ]

    ;; Create new link to show review
    create-review-link-with target [
      set disposition-score d-score ;; used for social layout
      set aptitude-score a-score ;; just storing
      set age 0
      set thickness 0.5 + (abs d-score - 50) / 20
      set color ifelse-value (d-score < 50) [red] [green]
      set label round d-score
    ]
  ]
end


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; LINK AGING
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to decay-links
  ask review-links [
    set age age + 1
    if age > 1 [ die ]
  ]
end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; REPUTATION DEMURRAGE
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to decay-reputation
 ; ask members [
  ;  let base 50
   ; set local-public-rep local-public-rep + ((base - local-public-rep) * 0.01)
  ;]
end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; MOVE AGENTS BY REVIEWS
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to pull-toward-review-partners
  ask review-links [
    let source end1
    let target end2
    let d-score disposition-score
    let pull-strength ((d-score - 50) / 50) ; from -1 to +1
    if pull-strength > 0 [
      let dx2 ([xcor] of target - [xcor] of source)
      let dy2 ([ycor] of target - [ycor] of source)
      ask source [
        setxy (xcor + (dx2 * 0.03 * pull-strength))
              (ycor + (dy2 * 0.03 * pull-strength))
      ]
    ]
  ]
end


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; VISUALIZATION
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to update-visuals
 ; ask members [
; ifelse culcus < 30 [
;  set color gray
;] [
;  set color blue
;]
;    set label round local-public-rep
;  ]


 ask members [
    ;ifelse nac-quality < 30 [
  ;      set color red
;] [
;  set color blue
;]
set label word "Rep: " word (round local-public-rep) word " | D: " word (round true-disposition) word " | A: " (round true-aptitude)

       ifelse self = current-host [
      set color yellow  ;; highlight the host
      set shape "star"  ;; or "target", "triangle", etc.
      set size 2        ;; make them stand out
    ] [
      let trait-color 0
      if layout-mode = "aptitude" [ set trait-color true-aptitude ]
      if layout-mode = "disposition" [ set trait-color true-disposition ]
      if layout-mode = "reputation" [ set trait-color local-public-rep ]

      set color scale-color blue trait-color 0 100

      set shape "circle"
      set size 1.5
    ]
  ]
end

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Starting Layout
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

to layout-by-mode
  let sorted-members nobody

  if layout-mode = "aptitude" [
    set sorted-members sort-by [[a b] -> [true-aptitude] of a < [true-aptitude] of b] members
  ]
  if layout-mode = "disposition" [
    set sorted-members sort-by [[a b] -> [true-disposition] of a < [true-disposition] of b] members
  ]
  if layout-mode = "reputation" [
    set sorted-members sort-by [[a b] -> [local-public-rep] of a < [local-public-rep] of b] members
  ]

  ;; Circular layout
  let radius 10
  let count-members length sorted-members
  let index 0

  foreach sorted-members [
    m ->
      let angle (index * 360 / count-members)
      let x radius * cos angle
      let y radius * sin angle
      ask m [ setxy x y ]
      set index index + 1
  ]
end



@#$#@#$#@
GRAPHICS-WINDOW
255
4
828
578
-1
-1
17.12121212121212
1
10
1
1
1
0
0
0
1
-16
16
-16
16
0
0
1
ticks
30.0

BUTTON
3
13
69
46
NIL
setup
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
74
13
139
46
NIL
go
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
145
13
208
46
NIL
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

MONITOR
120
225
207
270
Average Rep
mean [local-public-rep] of members
2
1
11

PLOT
256
587
547
739
Reputation
Time
Rep
0.0
10.0
50.0
10.0
true
true
"" "set-current-plot-pen \"avg-rep\"\nplot mean [local-public-rep] of members\nset-current-plot-pen \"top-rep\"\nplot max [local-public-rep] of members\nset-current-plot-pen \"low-rep\"\nplot min [local-public-rep] of members"
PENS
"avg-rep" 1.0 0 -16777216 true "" ""
"top-rep" 1.0 0 -14439633 true "" ""
"low-rep" 1.0 0 -2674135 true "" ""

MONITOR
25
225
112
270
Avg. Culcus
mean [culcus] of members
17
1
11

SLIDER
0
57
152
90
host-review-weight
host-review-weight
0
2
1.0
0.1
1
NIL
HORIZONTAL

PLOT
848
11
1136
160
Disposition vs. Reputation
Disposition
Reputation
0.0
10.0
0.0
10.0
true
false
"" "set-current-plot-pen \"disp-vs-rep\"\nforeach sort members [\n  m ->\n    plotxy [true-disposition] of m [local-public-rep] of m\n]\n"
PENS
"disp-vs-rep" 1.0 2 -16777216 true "" ""

PLOT
849
326
1136
485
True vs. Reviewed Aptitude
True A
Reviewed A
0.0
10.0
0.0
10.0
true
false
"" "set-current-plot-pen \"aptitude-accuracy\"\nforeach sort members [\n  m ->\n    plotxy [true-aptitude] of m [reviewed-aptitude] of m\n]\n"
PENS
"aptitude-accuracy" 1.0 2 -16777216 true "" "plot count turtles"

SLIDER
0
96
190
129
starting-rep-variation
starting-rep-variation
0
100
0.0
1
1
NIL
HORIZONTAL

SLIDER
1
138
221
171
starting-aptitude-variation
starting-aptitude-variation
0
100
30.0
1
1
NIL
HORIZONTAL

SLIDER
1
182
221
215
starting-disp-variation
starting-disp-variation
0
100
30.0
1
1
NIL
HORIZONTAL

CHOOSER
157
49
249
94
layout-mode
layout-mode
"aptitude" "disposition" "reputation"
0

SLIDER
9
327
181
360
base-growth
base-growth
0
1
0.2
0.1
1
NIL
HORIZONTAL

SLIDER
9
371
209
404
delta-growth-multiplier
delta-growth-multiplier
0.00
0.2
0.1
0.01
1
NIL
HORIZONTAL

SLIDER
9
413
211
446
participation-rep-bump
participation-rep-bump
0.0
2.0
0.2
0.1
1
NIL
HORIZONTAL

MONITOR
119
275
211
320
Avg. True Apt
mean [true-aptitude] of members
2
1
11

MONITOR
23
276
117
321
Avg. True Disp
mean [true-disposition] of members
2
1
11

MONITOR
10
456
154
501
Avg. Opportunity Count
mean [opportunity-count] of members
0
1
11

PLOT
849
167
1135
317
Rep and Disp Over Time
Time
NIL
0.0
10.0
0.0
10.0
true
true
"" "if ticks > 0 [\n\nset-current-plot-pen \"rep\"\nplot mean [local-public-rep] of members\nset-current-plot-pen \"disp\"\nplot mean [true-disposition] of members\n\n]"
PENS
"rep" 1.0 2 -16777216 true "" "plot count turtles"
"disp" 1.0 2 -7500403 true "" "plot count turtles"

PLOT
557
586
828
741
Participation vs. Aptitude
Opp Count
Aptitude
0.0
10.0
0.0
10.0
true
false
"" "if ticks > 0 [\n\nforeach sort members [\n  m ->\n  plotxy [opportunity-count] of m [true-aptitude] of m\n]\n\n]\n"
PENS
"default" 1.0 2 -16777216 true "" "plot count turtles"

PLOT
848
491
1143
648
Aptitude and Reputation, Col by Disposition
Aptitude
Reputation
0.0
150.0
50.0
100.0
true
false
"" "\nask members [\n  let c scale-color red true-disposition 0 100\n  set-plot-pen-color c\n  plotxy true-aptitude local-public-rep\n]\n"
PENS
"default" 1.0 2 -16777216 true "" "plot count turtles"

PLOT
847
651
1154
801
Participation and Reputation, Col by Disposition
Participation
Reputation
0.0
10.0
0.0
10.0
true
false
"" "ask members [\n  let c scale-color red true-disposition 0 100\n  set-plot-pen-color c\n  plotxy opportunity-count local-public-rep\n]"
PENS
"default" 1.0 2 -16777216 true "" "plot count turtles"

@#$#@#$#@
## WHAT IS IT?
This model simulates how reputation and skill (aptitude) evolve over time in a peer-based guild or learning community. It captures how individuals evaluate each other after collaborative opportunities (e.g., projects, events), and how reputation reflects not just skill but behavior — namely, disposition (how you treat others).

The model distinguishes between "true" internal attributes (aptitude, disposition) and "reviewed" perceptions of those attributes (based on noisy feedback from peers), allowing us to explore how social feedback shapes growth, reputation, and social structure.

## HOW IT WORKS
Agents (members) have two core internal traits: true-aptitude (A) and true-disposition (D), both initialized with random variation.

Each tick, one member may host an opportunity. Others decide whether to join based on the host’s reputation (relative to the group) and aptitude difference (i.e., how much more the host knows).

After each opportunity, all participants review each other on aptitude and disposition. Reviews are noisy but centered on true values.

Disposition reviews influence reputation. Aptitude reviews update each agent's reviewed-aptitude, which guides future participation.

Participation causes aptitude to grow, especially when learning from someone more advanced.

Reputation grows through participation (a base bump) and is further modified by the quality of disposition reviews.

Visual layout and plot options allow users to explore how the system evolves over time.

## HOW TO USE IT
Buttons:
setup: Initializes the model with agents and attributes.

go: Runs the simulation continuously.

go once: Advances one tick at a time.

Sliders:
starting-rep-variation: Controls initial differences in reputation.

starting-aptitude-variation: Controls initial skill differences.

starting-disp-variation: Controls initial behavior/disposition differences.

base-growth: Base increase in aptitude from any opportunity.

delta-growth-multiplier: Bonus learning from being around more skilled hosts.

participation-rep-bump: Fixed reputation gain from participating.

host-review-weight: Multiplier for reviews received as a host.

Chooser:
layout-mode: Arranges agents in a circle by aptitude, disposition, or reputation for visual clarity.

Monitors:
Track average culcus (host eligibility), reputation, disposition, aptitude, and opportunity counts.

## THINGS TO NOTICE
Agents with low aptitude tend to participate more early on — they learn faster and catch up.

Some agents gain high reputation even with lower skill, due to strong disposition.

Over time, true aptitude converges, while reputation continues to differentiate agents.

Visual clustering emerges as agents move closer to those they rate highly.

Feedback loops: positive reviews → higher reputation → more opportunities → more growth.

## THINGS TO TRY
Set starting-disp-variation to 0 to isolate aptitude dynamics.

Set host-review-weight to 1.0 to emphasize the reputation boost from hosting.

Try high delta-growth-multiplier to simulate strong mentorship effects.

Experiment with layout-mode to see how reputation, disposition, or aptitude relate spatially.

Watch how reviewed-aptitude compares to true aptitude in the plots.

## EXTENDING THE MODEL
Introduce Bayesian review aggregation to correct noisy reputation signals.

Add malicious agents or review manipulators to study system resilience.

Introduce group/guild identity, where agents only participate with familiar others.

Add a cost to participation or limited capacity, forcing selective choices.

Make culcus a visible currency to unlock advanced opportunities.

Separate host aptitude and opportunity quality, to simulate curation effects.

## NETLOGO FEATURES
Uses breed and undirected-link-breed for flexible agent interactions and visual links.

Dynamic layout-by-mode arranges turtles in a circular formation sorted by traits.

Plots visualize time-series and pairwise comparisons between attributes.

scale-color dynamically visualizes aptitude or disposition based on layout.

Custom go logic includes learning loops, review noise, and conditional participation.
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
