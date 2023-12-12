---
description: Guide for handling emergencies
---

# Emergency Procedures

Got a bug to report? Reach out to us at engineering@opus.money

## Introduction

This document, drawing heavily from Yearn Finance, details the procedures and guidelines that should take place in the event of an emergency situation. Its purpose is to minimize the risk of loss of funds for Opus' users, treasury and smart contracts.

## Definitions and Examples of Emergencies

For the purposes of this document, an emergency situation is defined as:

**Any situation that may lead to the loss of a considerable amount of funds for Opus' users, Opus' treasury or smart contracts deployed by Opus.**

This is a non-exhaustive list of possible emergency scenarios:

1. Bug/exploit in any of the deployed smart contracts that can cause a loss of funds for users.
2. Bug/exploit in any of the assets that is onboarded as a `yang` that may lead to loss of funds.
3. Loss of private keys for a key role, such as the admin.
4. Potential exploit discovered by a team or bounty program researcher.
5. Active exploit/hack in progress discovered by an unknown party.
6. Bug/exploit in Opus' frontend allowing an attacker to phish users.

## Roles

In the event of an emergency situation, the following roles should be assigned to the contributors working to resolve the situation:

* Facilitator
* Multi-sig Herder
* Core Dev Lead
* Web Lead
* Ops

A contributor may be assigned up to two of these roles concurrently.

### Facilitator

The Facilitator is responsible for:

* facilitating the handling of the emergency;
* ensuring the process described in this document is adhered to; and
* engaging with the correct stakeholders and teams in order for the necessary decisions to be made in an expedient manner.

A suitable Facilitator is someone familiar with the emergency process, and is confident in driving the team to follow through on the tasks. It is expected that the person assigned to this role has relevant experience, either from having worked in real scenarios or through training drills.

### Multi-sig Herder

The Multi-sig Herder is responsible for:

* ensuring the relevant multi-sig wallets are able to execute transactions in a timely manner during the emergency;
* helping to clear the queue of any pending operations once the War Room starts;
* coordinate required signers so they can respond quickly to queued transactions;
* prepare or help with transactions in one or more multi-sigs.

### Core Dev Lead

The Core Dev Lead is responsible for:

* coordinating quick changes to access control roles during the emergency;
* preparing and executing relevant multi-sig transactions and operations;
* pausing minting of new `yin` by setting the debt ceiling to zero.
* shutdown one or more modules by calling `kill()` or `kill_gate()`;
* shutdown the protocol by calling `Caretaker.shut()`.

### Web Lead

The Web Lead is responsible for:

* coordinating changes to the UI and website in an expedient manner, including but not limited to, displaying alets and banners, or disabling certain user interactions on the UI.

### Ops

The Ops personnel is responsible for:

* coordinating communications and operations assistance as required;
* clear with War Room what information and communication can be published during and after the emergency;
* take note of timelines and events for disclosure.

## Emergency Steps

This acts as a guideline to follow when an incident is reported requiring immediate attention.

The primary objective is to minimize the loss of funds, in particular for our users. All decisions made should be driven by this goal.

1. Create a private Slack channel ("**War Room**") and invite only the team members that are online that can cover the roles described above. The War Room is limited to members that act in the capacities of the designated roles, as well as additional individuals that can provide critical insight into the circumstances of the issue and how it can be best resolved.
2. All the information gathered during the War Room should be considered private to the chat and are not to be shared with third parties. The Facilitator should pin and update relevant data for the team to have them on hand.
3. The team's first milestone is to assess the situation as quickly as possible, confirm the reported information and determine how critical the incident is. A few questions to guide this process:
   * Is there confirmation from several team members/sources that the issue is valid? Are there example transactions that show the incident occuring? These should be pinned in the War Room, if any.
   * Is a core developer in the War Room? Can any of the core developers be reached? If not, can we reach out to other smart contract developers familiar with the codebase?
   * Are funds presently at risk? Is immediate action required?
   * Is the issue isolated or does it affect several smart contracts? Can the affected smart contracts be identified? These should be pinned in the war room, if any.
   * The Multi-sig Herder should begin to notify signers and clear the queue in preparation for emergency transactions.
   * If there is no immediate risk of loss of funds, does the team still need to take preventive action or some other mitigation?
   * Is there agreement in the team that the situation is under control and that the War Room can be closed?
4. Once the issue has been confirmed as valid, the next step is to take immediate corrective action to prevent further loss of funds. If the root cause requires further research, the team must err on the side of caution and take emergency preventive actions while the situation continues to be assessed. A few questions to guide the decisions of the team:
   * Should the minting of new `yin` be paused? If yes, call `shrine.set_ceiling` and set the new ceiling to zero.
   * Should deposits of collateral into a trove be disabled? If yes, call `sentinel.set_yang_asset_max` and set it to lower value than what is currently in the Gate.
   * Should any Gate be killed? This may be warranted if a specific collateral type is at risk in an incident so as to prevent further user losses from making new deposits. If yes, call `sentinel.kill_gate()`&#x20;
   * Should the Absorber be killed? This may be warranted if the Absorber's `yin` is at risk in an incident so as to prevent further user losses from providing more `yin`. If yes, call `absorber.kill()`.
   * Should global shutdown be triggered? This may be warranted if there is a risk that the total value of collateral assets held in the protocol will be insufficient to back the total supply of `yin`. If yes, call `caretaker.shut()`.
   * Should any user actions be removed from the UI?
   * Are multiple team members able to confirm the corrective actions will stop the immediate risk through local fork testing? The Core Dev Lead must confirm this step.
5. The immediate corrective actions should be scripted and executed ASAP. The Multi-sig Herder should coordinate this execution within the corresponding roles. **NOTE: This step is meant to give the War Room time to assess and research a more long-term solution.**
6. Once corrective measures are in place, and there is confirmation by multiple sources that funds are no longer at risk, the next objective is to identify the root cause. A few question/actions during this step that can help the team decide:
   * What communications should be made public at this point?
   * Can research among members of the War Room be divided? This step can be open for team members to do live debug sessions sharing screens to help identify the problem using the sample transactions.
7. Once the cause is identified, the team can brainstorm to come up with the most suitable remediation plan and its code implementation (if required). A few questions that can help during this time:
   1. In case there are many possible solutions, can the team prioritize by weighing each option by time to implement and minimization of losses?
   2. Can the possible solutions be tested and compared to confirm the end state fixes the issue?
   3. Is there agreement in the War Room about the best solution? If not, can the objections be identified and a path for how to reach consensus on the approach be worked out, prioritizing the minimization of losses?
   4. If a solution will take longer than a few hours, are there any further communications and preventive actions needed while the fix is developed?
   5. Does the solution require a longer-term plan? Are there identified owners for the tasks/steps for the plan's execution?
8. Once a solution has been implemented, the team will confirm the solution resolves the issue and minimizes the loss of funds. Possible actions needed during this step:
   1. Run fork simulations of the end state to confirm the proposed solution(s)
   2. Coordinate signatures from multi-sig signers and execution
   3. Enable UI changes to normalize operations as needed
9. Assign a lead to prepare a disclosure (should it be required), preparing a timeline of the events that took place.
10. The team agrees when the War Room can be dismantled. The Facilitator breaks down the War Room and sets reminders if it takes longer than a few hours for members to reconvene.

## Emergency Checklist

This checklist should be complemented with the steps:

* [ ] Create War Room with audio
* [ ] Assign Key Roles to War Room members
* [ ] Add Core Dev (or their backup) to the War Room
* [ ] Clear related multi-sig queues
* [ ] Disable deposits, withdrawals and/or other user actions as needed in the web UI
* [ ] Confirm and identify issue
* [ ] Take immediate corrective/preventive actions to prevent (further) loss of funds
* [ ] Communicate the current situation internally and externally (as appropriate)
* [ ] Determine the root cause
* [ ] Propose workable solutions
* [ ] Implement and validate solutions
* [ ] Prioritize solutions
* [ ] Reach an agreement within the Team on the best solution
* [ ] Execute solution
* [ ] Confirm incident has been resolved
* [ ] Assign ownership of security disclosure report
* [ ] Disband War Room
* [ ] Conduct immediate debrief
* [ ] Schedule a Post-Mortem

## Tools

List of tools and alternatives in case primary tools are not available during an incident.

| Description         | Primary     | Secondary         |
| ------------------- | ----------- | ----------------- |
| Code Sharing        | GitHub      | HackMD, CodeShare |
| Communications      | Slack       | Telegram          |
| Transaction Details | Voyager     | Starkscan         |
| Debugging           | TODO        |                   |
| Transaction Builder | TODO        |                   |
| Screen Sharing      | Google Meet | jitsi             |

**The Facilitator is responsible for ensuring that no unauthorized persons enter the War Room or join these tools via invite links that leak.**

## Incident Post Mortem

A Post Mortem should be conducted after an incident to gather data and feedback from the War Room participants in order to produce actionable improvements for our processes such as this one.

Following the dissolution of a War Room, the Facilitator should ideally conduct an immediate informal debrief to gather initial notes before they are forgotten by participants.

This can then be complemented by a more extensive Post Mortem as outlined below.

The Post Mortem should be conducted at most a week following the incident to ensure a fresh recollection by the participants.

It is key that most of the participants of the War Room are involved during this session in order for an accurate assessment of the events that took place. Discussion is encouraged. The objective is to collect constructive feedback for how the process can be improved, and not to assign blame to any War Room participants.

Participants are encouraged to provide inputs on each of the steps. If a participant does not, the Facilitator is expected to try to obtain more feedback by asking probing questions.

### Post Mortem Outputs

* List what went well
* List what can be improved
* List questions that came up in the Post Mortem
* List insights from the process
* Root Cause Analysis along with concrete measures required to prevent the incident from ever happening again
* List of action items assigned to owners with estimates for completion

### Post Mortem Steps

1. Facilitator runs the session in a voice channel and shares their screen for participants to follow.
2. Facilitator runs through an agenda to obtain the necessary outputs listed above.
3. For the Root Cause Analysis, the Facilitator conducts an exercise to write the problem statement first, and then confirm with the participants that the statement is correct and understood.
4. Root Cause Analysis can be identified with the following tools:
   1. Brainstorming session with participants
   2. [5 Whys](https://en.wikipedia.org/wiki/Five\_whys) Technique (illustrative [example](https://twitter.com/storming0x/status/1732217083188920625/photo/1))
5. Once the Root Causes have been identified, action items can be written and assigned to willing participants that can own the tasks. It is recommended that an estimated time for completion is given. A later process can track completion of given assignments. **Note: The action items need to be clear, actionable and measurable for completion.**
6. The Facilitator tracks completion of action items. The end result of the process should be an actionable improvement in the process. Some possible improvements:
   * Changes in the process and documentation
   * Changes in code and tests to validate
   * Changes in tools implemented and incorporated into the process
