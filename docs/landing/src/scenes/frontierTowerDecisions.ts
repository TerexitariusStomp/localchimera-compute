export interface TowerDecisionScene {
  id: number;
  title: string;
  description: string;
  context: string; // Story context
  setup?: string; // Code to run before scene
  choices: {
    id: string;
    title: string;
    description: string;
    impact: string; // What happens
    code?: string; // Code to execute on choice
  }[];
  unlockPlayground?: boolean;
}

export const towerDecisions: TowerDecisionScene[] = [
  {
    id: 1,
    title: "A New Member Arrives",
    description: "Sofia, a robotics founder, wants to join Frontier Tower. Floor 7 has space.",
    context: "Frontier Tower is co-owned by its members. Each member represents themselves in the main tower organization, and each floor operates as its own sub-organization.",
    setup: "(modify! 'budget 50000) (defexpressor 'floor7 \"floor7-key\") (defexpressor 'floor12 \"floor12-key\")",
    choices: [
      {
        id: 'accept',
        title: 'Accept Sofia',
        description: 'Floor 7 votes to accept her',
        impact: 'Sofia joins Floor 7, becoming a member-owner',
        code: "(defexpressor 'sofia \"sofia-key\") (as floor7 (modify! 'new-member 'sofia))"
      },
      {
        id: 'defer',
        title: 'Defer to Full Tower',
        description: 'Let all floors vote on new members',
        impact: 'Decision goes to the broader community',
        code: "(modify! 'pending-member 'sofia)"
      }
    ]
  },
  {
    id: 2,
    title: "Rooftop Garden Proposal",
    description: "Floor 12 proposes converting the rooftop into a shared garden. Cost: $50k from shared funds.",
    context: "The tower has shared resources. Major expenditures need approval, but how? Should it be democratic, weighted by floor size, or require consensus?",
    choices: [
      {
        id: 'install-validator',
        title: 'Create Budget Rules',
        description: 'Install a validator: All expenses >$10k need approval',
        impact: 'Future proposals must pass validation',
        code: "(enact! (lambda (exp name val old new) (or (< val 10000) (approved? val))))"
      },
      {
        id: 'vote-now',
        title: 'Just Vote on This One',
        description: 'Vote yes/no on the garden, no permanent rules',
        impact: 'No validator, keep flexibility',
        code: "(modify! 'rooftop-decision 'approved)"
      },
      {
        id: 'delegate',
        title: 'Delegate to Floor Reps',
        description: 'Create a representative council for these decisions',
        impact: 'Form governance layer',
        code: "(defexpressor 'council \"council-key\") (as council (modify! 'rooftop-decision 'approved))"
      }
    ],
    unlockPlayground: true
  },
  {
    id: 3,
    title: "Noise Complaint",
    description: "Floor 3 is hosting late-night events. Floor 4 complains it violates quiet hours (11pm-7am).",
    context: "The tower has basic rules, but they're loosely enforced. Should rules be stricter? Should violators face consequences?",
    choices: [
      {
        id: 'strict',
        title: 'Strict Enforcement',
        description: 'Automatic fines for rule violations',
        impact: 'Rules become binding with penalties',
        code: "(enact! (lambda (exp name val old new) (and (valid-hours? val) (quiet? val))))"
      },
      {
        id: 'mediation',
        title: 'Mediation Process',
        description: 'Floors 3 and 4 negotiate their own solution',
        impact: 'Trust community to self-organize',
        code: "(as floor3 (modify! 'event-policy 'negotiated)) (as floor4 (modify! 'complaint 'resolved))"
      },
      {
        id: 'reputation',
        title: 'Reputation System',
        description: 'Track floor behavior, bad actors lose voting power',
        impact: 'Emergent incentives through reputation',
        code: "(modify! 'floor3-reputation (- (get 'floor3-reputation) 10))"
      }
    ]
  },
  {
    id: 4,
    title: "Budget Crisis",
    description: "Expenses exceeded projections. The tower needs $100k. Raise dues or cut amenities?",
    context: "Financial stress tests governance. Do floors with more members pay more? Should payments be voluntary? Can floors override the decision?",
    choices: [
      {
        id: 'proportional',
        title: 'Proportional Dues',
        description: 'Floors pay based on their member count',
        impact: 'Fair, but large floors may resist',
        code: "(modify! 'dues-model 'proportional) (modify! 'floor12-dues 15000) (modify! 'floor7-dues 8000)"
      },
      {
        id: 'voluntary',
        title: 'Voluntary Contributions',
        description: 'Ask floors to contribute what they can',
        impact: 'Risks underfunding, but preserves autonomy',
        code: "(modify! 'dues-model 'voluntary) (modify! 'funding-status 'uncertain)"
      },
      {
        id: 'cut-amenities',
        title: 'Cut Non-Essential Amenities',
        description: 'Reduce services to stay within budget',
        impact: 'No extra fees, but reduced quality of life',
        code: "(modify! 'amenities 'reduced) (modify! 'gym 'closed) (modify! 'rooftop-access 'limited)"
      }
    ],
    unlockPlayground: true
  },
  {
    id: 5,
    title: "A Floor Wants to Exit",
    description: "Floor 9 wants to leave the tower's governance but stay physically. They reject the latest budget vote.",
    context: "Can a floor fork the organization? Should history preserve dissenting votes? What happens to their ownership stake?",
    choices: [
      {
        id: 'fork',
        title: 'Allow Fork',
        description: 'Floor 9 becomes independent, keeps their physical space',
        impact: 'Creates parallel governance structures',
        code: "(rollback! 3) (defexpressor 'floor9-independent \"floor9-key\")"
      },
      {
        id: 'buyout',
        title: 'Buyout Mechanism',
        description: 'Floor 9 buys out their stake, leaves completely',
        impact: 'Clean exit, tower retains cohesion',
        code: "(modify! 'floor9 'exited) (modify! 'tower-funds (+ (get 'tower-funds) 500000))"
      },
      {
        id: 'compromise',
        title: 'Nested Autonomy',
        description: 'Floor 9 stays but opts out of certain votes',
        impact: 'Flexible, but complex governance',
        code: "(as floor9 (modify! 'autonomy-level 'partial)) (modify! 'governance-mode 'nested)"
      }
    ]
  },
  {
    id: 6,
    title: "The Tower Evolves",
    description: "After months of decisions, what has Frontier Tower become?",
    context: "playnet didn't prescribe the outcome. The choices shaped it. This is just one possible path.",
    choices: [
      {
        id: 'democracy',
        title: 'Thriving Democracy',
        description: 'Regular votes, active participation, transparent decisions',
        impact: 'The tower is a model for co-living governance',
        code: "(modify! 'governance-model 'democratic) (modify! 'member-satisfaction 'high)"
      },
      {
        id: 'fragmented',
        title: 'Fragmented Collective',
        description: 'Floors operate independently, minimal coordination',
        impact: 'Flexible but disconnected',
        code: "(modify! 'governance-model 'fragmented) (modify! 'floor-autonomy 'maximum)"
      },
      {
        id: 'representative',
        title: 'Representative Council',
        description: 'Elected floor reps make most decisions',
        impact: 'Efficient but less direct democracy',
        code: "(modify! 'governance-model 'representative) (defexpressor 'council-chair \"chair-key\")"
      },
      {
        id: 'liquid',
        title: 'Liquid Democracy',
        description: 'Members delegate voting power, reclaim it anytime',
        impact: 'Adaptive, reputation-driven governance',
        code: "(modify! 'governance-model 'liquid) (modify! 'delegation-active #t)"
      }
    ],
    unlockPlayground: true
  }
];
