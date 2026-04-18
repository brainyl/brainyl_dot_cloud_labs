
*Hands-on lab with Amazon Lex V2, Lambda integration, and conversational AI*

## Prerequisites

Before starting this lab, ensure you have:

- AWS Account with admin access
- All resources will be created in **us-west-2**
- Basic understanding of conversational interfaces

## Lab Overview

You'll build a conversational AI chatbot that helps users book AWS mentorship sessions. The bot validates user inputs (program type and commitment duration) and provides a complete booking flow with confirmation.

**Important:** In Amazon Lex V2, slot types are scoped to individual bots, so you must create the bot first before creating custom slot types.

---

## Task 1: Create Lex Bot

### 1.1 Navigate to Amazon Lex

1. **Sign in to AWS Console**
2. **Search for "Lex" in the search bar** and select **Amazon Lex**
3. **Ensure you're in us-west-2 region** (check top-right corner)

### 1.2 Create Bot

1. In the left menu, choose **Bots** and click **Create bot**.

#### Creation method

   - Select **Traditional** (default).
   - Choose **Create a blank bot**.

#### Bot configuration

   - Set **Bot name** to `MentorshipBot`.
   - (Optional) Add a **Description** such as `AWS mentorship booking assistant`.

#### IAM permissions

   - Leave **Runtime role** as **Create a role with basic Amazon Lex permissions** (default).
   - Click **Next** to move to page 2.

#### Page 2 – Children's Online Privacy Protection Act (COPPA)

   - Select **No**.

#### Idle session timeout

   - Keep the default `5 minute(s)`.

#### Add language to bot

   - Language: **English (US)** (default).
   - Description: leave blank (optional).
   - Voice interaction: keep **Danielle** (default).
   - Intent classification confidence score threshold: keep **0.40** (default).

#### Finish

   - Click **Done**. Lex opens the intent builder with the default **NewIntent**.

---

## Task 2: Rename Default Intent

### 2.1 Rename NewIntent to BookAWSMentorship

1. **You'll see "Intent: NewIntent" at the top of the page**
2. **Scroll down to "Intent details" section**
3. **In "Intent name" field, change `NewIntent` to `BookAWSMentorship`**
4. **Scroll to the bottom and click "Save intent"**

---

## Task 3: Create Custom Slot Type

### 3.1 Create Custom Slot Type for Program Types

1. From the left menu, open **Slot types** and choose **Add slot type → Add blank slot type**.

#### Slot type configuration

   - Slot type name: `ProgramType`
   - Description: `AWS mentorship program types`
   - Slot value resolution: **Restrict to slot values**

#### Add slot values

   - Click **Add slot value** and enter `CCP`, `SA`, and `GenAI` (press Enter after each value).
   - Click **Save slot type**.

---

## Task 4: Configure Intent with Slots and Utterances

### 4.1 Return to BookAWSMentorship Intent

1. **In left menu: Intents**
2. **Click on "BookAWSMentorship"**

### 4.2 Add Sample Utterances

1. In the **Sample utterances** section, click **Add utterance**.
2. Enter `Book AWS mentorship` and press Enter to save it.

### 4.3 Add Slots

1. Scroll to the **Slots** section and click **Add slot**.

#### Slot 1 – ProgramType

   - Name: `ProgramType`
   - Slot type: select the custom **ProgramType** slot type
   - Prompt: `Which program are you interested in? CCP, SA, or GenAI?`
   - Click **Add**.

2. Click **Add slot** again.

#### Slot 2 – StartDate

   - Name: `StartDate`
   - Slot type: search and select **AMAZON.Date**
   - Prompt: `When do you want to start?`
   - Click **Add**.

3. Click **Add slot** once more.

#### Slot 3 – Months

   - Name: `Months`
   - Slot type: search and select **AMAZON.Number**
   - Prompt: `How many months do you want to commit to? (3-6 months)`
   - Click **Add**.

### 4.4 Configure All Slots as Required

- In the **Slots** section, check **Required** for `ProgramType`, `StartDate`, and `Months`.

### 4.5 Configure Confirmation

1. Scroll to the **Confirmation** section and toggle **Confirmation** on.

#### Confirmation prompt

   - Click **Add message** and enter: `Great! Just to confirm - you want to book {ProgramType} mentorship starting {StartDate} for {Months} months. Is that correct?`

#### Decline response

   - Under **Decline responses**, click **Add message** and enter: `No problem. Let's start over. What can I help you with?`

### 4.6 Save Intent

1. **Click "Save intent" button** (bottom of page)

### 4.7 Build Bot (Initial Version)

1. **Click "Build" button** (top-right)
2. **Wait for build to complete** (takes 30-60 seconds)

### 4.8 Test Bot (Without Lambda)

1. **Click "Test" button** (top-right) to open test window
2. **In the chat window, type:** `Book AWS mentorship`
3. **Follow the prompts:**
    - Program: `CCP`
    - Start date: `tomorrow`
    - Months: `5`
    - Confirmation: `yes`
4. **Expected Result:** Bot collects all slots and confirms (no validation yet - any month value will be accepted)

---

## Task 5: Create Lambda Function for Validation

### 5.1 Create Lambda Function

1. Open a new tab, navigate to the **Lambda** service, and click **Create function**.

#### Function configuration

   - Select **Author from scratch**.
   - Function name: `LexMentorshipValidator`.
   - Runtime: **Python 3.12**.
   - Architecture: **x86_64**.

2. Expand **Change default execution role** and choose **Create a new role with basic Lambda permissions**.
3. Click **Create function**.

### 5.2 Add Lambda Code

1. **In the "Code" tab, scroll to "Code source" section**
2. **Delete existing code in `lambda_function.py`**
3. **Copy the following code:**

```python
"""
Lambda function for Amazon Lex V2 mentorship booking validation
Validates:
- Program type (CCP, SA, GenAI)
- Commitment duration (3-6 months)
"""

import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Amazon Lex V2 Lambda handler
    Handles both DialogCodeHook (validation) and FulfillmentCodeHook
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    intent_name = event['sessionState']['intent']['name']
    invocation_source = event['invocationSource']
    
    if intent_name == 'BookAWSMentorship':
        if invocation_source == 'DialogCodeHook':
            return validate_mentorship_booking(event)
        elif invocation_source == 'FulfillmentCodeHook':
            return fulfill_mentorship_booking(event)
    
    return close(
        event,
        'Fulfilled',
        'Thanks for contacting AWS mentorship support!'
    )


def validate_mentorship_booking(event):
    """Validate slot values during dialog"""
    slots = event['sessionState']['intent']['slots']
    
    # Validate Months slot (must be between 3-6)
    if slots.get('Months') and slots['Months'].get('value'):
        months_value = slots['Months']['value']['interpretedValue']
        try:
            months = int(months_value)
            if months < 3 or months > 6:
                return elicit_slot(
                    event,
                    'Months',
                    'Commitment must be between 3 and 6 months. Please choose a valid duration.'
                )
        except ValueError:
            return elicit_slot(
                event,
                'Months',
                'Please provide a valid number of months (3-6).'
            )
    
    # All validations passed - delegate back to Lex
    return delegate(event)


def fulfill_mentorship_booking(event):
    """Fulfill the intent after confirmation"""
    slots = event['sessionState']['intent']['slots']
    
    program = slots['ProgramType']['value']['interpretedValue']
    start_date = slots['StartDate']['value']['interpretedValue']
    months = slots['Months']['value']['interpretedValue']
    
    message = (
        f"Thanks! I have booked your AWS mentorship session. "
        f"You'll receive a confirmation email shortly."
    )
    
    return close(event, 'Fulfilled', message)


def delegate(event):
    """Delegate back to Lex to continue the dialog"""
    return {
        'sessionState': {
            'dialogAction': {
                'type': 'Delegate'
            },
            'intent': event['sessionState']['intent']
        }
    }


def elicit_slot(event, slot_to_elicit, message):
    """Prompt user to provide a specific slot value"""
    return {
        'sessionState': {
            'dialogAction': {
                'type': 'ElicitSlot',
                'slotToElicit': slot_to_elicit
            },
            'intent': event['sessionState']['intent']
        },
        'messages': [
            {
                'contentType': 'PlainText',
                'content': message
            }
        ]
    }


def close(event, fulfillment_state, message):
    """Close the dialog with a final message"""
    return {
        'sessionState': {
            'dialogAction': {
                'type': 'Close'
            },
            'intent': {
                'name': event['sessionState']['intent']['name'],
                'state': fulfillment_state
            }
        },
        'messages': [
            {
                'contentType': 'PlainText',
                'content': message
            }
        ]
    }
```

4. **Paste the code into the Lambda editor**
5. **Click "Deploy"** (above the code editor)
6. **Wait for "Successfully deployed" message**

---

## Task 6: Integrate Lambda with Lex

### 6.1 Enable Lambda Code Hooks in Intent

1. **Go back to Amazon Lex tab**
2. **In left menu: Intents → BookAWSMentorship**
3. **Scroll to "Code hooks - optional" section**
4. **Check "Use a Lambda function for initialization and validation"**
5. **Scroll to "Fulfillment" section**
6. **Expand "Advanced options"**
7. **Check "Use a Lambda function for fulfillment"**
8. **Click "Save intent"**

### 6.2 Set Lambda Function at Alias Level

1. In the left menu, open **Deployment → Aliases**.
2. Select the first alias (TestBotAlias) and choose **English (US)**.

#### Lambda function assignment

   - Pick `LexMentorshipValidator` from the **Lambda function (optional)** dropdown.
   - Click **Save**.

### 6.3 Build Bot

1. **Click "Build"** (top-right)
2. **Wait for build to complete** (30-60 seconds)

---

## Task 7: Test Complete Conversational Flow

### 7.1 Test Valid Scenario

1. **Click "Test"** (top-right)
2. **Type:** `Book AWS mentorship`
3. **Test conversation:**
    - Program: `SA`
    - Start date: `next Monday`
    - Months: `4`
    - Confirmation: `yes`
4. **Expected Result:** 
    - All validations pass
    - Final message: "Thanks! I have booked your AWS mentorship session. You'll receive a confirmation email shortly."

### 7.2 Test Invalid Month Range

1. **In test window, click "Clear chat"**
2. **Type:** `I want mentorship`
3. **Test conversation:**
    - Program: `GenAI`
    - Start date: `tomorrow`
    - Months: `2` (invalid - less than 3)
4. **Expected Result:**
    - Bot should reject and display: "Commitment must be between 3 and 6 months. Please choose a valid duration."
    - Bot re-prompts for Months
5. **Type:** `5`
6. **Confirmation:** `yes`
7. **Expected Result:** Booking should complete successfully

### 7.3 Test Invalid Month Range (Upper Bound)

1. **In test window, click "Clear chat"**
2. **Type:** `Book a mentorship session`
3. **Test conversation:**
    - Program: `CCP`
    - Start date: `2025-02-01`
    - Months: `12` (invalid - more than 6)
4. **Expected Result:**
    - Bot should reject with validation message
    - Bot re-prompts for Months
5. **Type:** `6`
6. **Confirmation:** `yes`
7. **Expected Result:** Booking should complete successfully

### 7.4 Test Decline Confirmation

1. **In test window, click "Clear chat"**
2. **Type:** `Schedule mentorship`
3. **Provide valid inputs:**
    - Program: `SA`
    - Start date: `next week`
    - Months: `3`
    - Confirmation: `no`
4. **Expected Result:**
    - Bot should show decline message
    - Conversation should restart

---

## Testing Summary

✅ **Task 1:** Bot `MentorshipBot` created successfully

✅ **Task 2:** Default intent renamed to `BookAWSMentorship`

✅ **Task 3:** Custom slot type `ProgramType` created with CCP, SA, GenAI values

✅ **Task 4:** Intent configured with slots, utterances, and confirmation

✅ **Task 5:** Lambda function validates month range (3-6) and program types

✅ **Task 6:** Lambda integrated with Lex for validation and fulfillment

✅ **Task 7:** Complete conversation flow with validation working  

---

## Clean Up (Optional)

### Delete in Order

#### Amazon Lex

   - Navigate to **Bots**.
   - Select `MentorshipBot`, choose **Actions → Delete**, and type the bot name to confirm.
   - Go to **Slot types**, select `ProgramType`, and delete it.

#### Lambda

   - Open the **Lambda** service.
   - Select `LexMentorshipValidator`, choose **Actions → Delete**, and confirm.

#### IAM Roles (Auto-created)

   - In **IAM → Roles**, search for entries containing `MentorshipBot` or `LexMentorshipValidator`
   - Delete the auto-created roles.

---

## Troubleshooting

### Bot Not Validating Inputs

- Verify Lambda is deployed after pasting code
- Check "Advanced options" is enabled for validation
- Rebuild bot after making Lambda configuration changes
- Check Lambda CloudWatch logs for errors

### Lambda Permission Errors

- Ensure resource-based policy is added to Lambda
- Principal must be `lexv2.amazonaws.com` (not lex.amazonaws.com)
- Rebuild bot to automatically grant permissions

### Slot Values Not Being Captured

- Ensure all three slots are marked as "Required"
- Check slot names match exactly: `ProgramType`, `StartDate`, `Months`
- Verify slot types are correct (custom type for ProgramType, AMAZON.Date, AMAZON.Number)

### Validation Logic Not Triggering

- Check Lambda CloudWatch logs (Monitor tab → View logs in CloudWatch)
- Verify Lambda code is deployed successfully
- Ensure months value is outside 3-6 range to test validation
- Rebuild bot after Lambda integration changes

### Bot Doesn't Show Fulfillment Message

- Verify fulfillment Lambda code hook is enabled
- Check FulfillmentCodeHook section in Lambda code
- Ensure bot is rebuilt after configuration changes

---

## What You've Learned

- Created custom slot types for controlled user inputs
- Built a multi-turn conversational bot with Amazon Lex V2
- Implemented business logic validation with Lambda
- Integrated Lambda code hooks for dialog management and fulfillment
- Tested conversational AI flows with various scenarios

---

**Lab Complete! You've successfully built an AWS Mentorship booking chatbot with intelligent validation!**

