export interface DecisionScene {
  id: number;
  title: string;
  description: string;
  setup?: string; // Code to run before scene
  choices: {
    id: string;
    title: string;
    description: string;
    code?: string; // Code to execute on choice
  }[];
  unlockPlayground?: boolean;
}

export const decisions: DecisionScene[] = [
  {
    id: 1,
    title: "Accept Alice's Proposal?",
    description: "Alice wants to add a proposal to the organization. Should we accept it?",
    setup: "(defexpressor 'alice \"alice-key\")",
    choices: [
      {
        id: 'accept',
        title: 'Accept',
        description: "Alice's proposal becomes real",
        code: "(as alice (modify! 'proposal \"fund the commons\"))"
      },
      {
        id: 'reject',
        title: 'Reject',
        description: 'Keep the organization unchanged'
      }
    ]
  },
  {
    id: 2,
    title: "Should Bob Be Able to Override?",
    description: "Bob wants to change Alice's proposal. Right now, there are no rules.",
    setup: "(defexpressor 'bob \"bob-key\")",
    choices: [
      {
        id: 'chaos',
        title: 'Allow Chaos',
        description: 'No rules, anyone can change anything'
      },
      {
        id: 'validator',
        title: 'Install a Validator',
        description: 'Create rules that gate all future changes',
        code: "(enact! (lambda (expressor name value old-env new-env) #t))"
      }
    ],
    unlockPlayground: true
  },
  {
    id: 3,
    title: "Make the Rule Stricter or Looser?",
    description: "You have a validator. Should it be strict or permissive?",
    choices: [
      {
        id: 'strict',
        title: 'Strict',
        description: 'Only numbers allowed',
        code: "(enact! (lambda (expressor name value old-env new-env) (number? value)))"
      },
      {
        id: 'loose',
        title: 'Loose',
        description: 'Most things pass through',
        code: "(enact! (lambda (expressor name value old-env new-env) (not (equal? value #f))))"
      },
      {
        id: 'custom',
        title: 'Custom',
        description: 'Write your own rule in the playground'
      }
    ]
  },
  {
    id: 4,
    title: "Someone Violates - Block or Allow?",
    description: "Charlie tries to add something that breaks the rules.",
    setup: "(defexpressor 'charlie \"charlie-key\")",
    choices: [
      {
        id: 'keep',
        title: 'Keep the Rule',
        description: 'Validator rejects it, organization stays stable'
      },
      {
        id: 'override',
        title: 'Override This Once',
        description: 'You have meta-control, accept it anyway'
      }
    ],
    unlockPlayground: true
  },
  {
    id: 5,
    title: "Conflict Emerges - Rollback or Fork?",
    description: "Something went wrong. The history trail is visible - what now?",
    choices: [
      {
        id: 'rollback',
        title: 'Rollback',
        description: 'Rewind time, undo the mistake'
      },
      {
        id: 'fork',
        title: 'Fork',
        description: 'Split into parallel realities, explore both paths'
      }
    ]
  },
  {
    id: 6,
    title: "What Kind of Org Does This Become?",
    description: "The substrate is ready. What emerges?",
    choices: [
      {
        id: 'democracy',
        title: 'Democracy',
        description: 'Consensus-based decision making'
      },
      {
        id: 'marketplace',
        title: 'Marketplace',
        description: 'Free exchange between expressors'
      },
      {
        id: 'neural',
        title: 'Neural Network',
        description: 'Layered processing, emergent intelligence'
      },
      {
        id: 'autocracy',
        title: 'Autocracy',
        description: 'One expressor controls all'
      }
    ],
    unlockPlayground: true
  }
];
