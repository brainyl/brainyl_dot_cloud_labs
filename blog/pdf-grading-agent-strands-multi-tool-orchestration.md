
In [Turn Your First Lambda Into a Strands Agent](./lambda-to-strands-agent.md), we built a translation agent that processed text and published results to SNS. That agent used a single tool for a straightforward task. Real-world document processing is more complex—multiple PDFs, structured data extraction, edge case handling, and maintaining accuracy when grading hundreds of submissions.

Grading PDF submissions at scale illustrates this complexity. When you're grading 10 students, you can manually review each submission. At 100 students across multiple assignments, the repetitive work becomes overwhelming—opening PDFs, comparing answers to keys, tallying scores, handling pre-filled examples, writing feedback. Manual grading doesn't scale, introduces inconsistencies, and pulls time away from actual teaching.

You could send both PDFs directly to an LLM and ask it to grade everything, but LLMs can hallucinate when extracting structured data from complex layouts—misreading question numbers, skipping answers, or incorrectly parsing multi-line responses. For grading, accuracy is non-negotiable. A single hallucinated answer extraction undermines trust in the entire system.

This playbook shows you how to build a production-minded grading agent that balances LLM reasoning with deterministic data processing. The agent uses four specialized tools—`extract_pdf_text`, `extract_answer_key`, `extract_student_answers`, and `compare_answers`—to handle the predictable parts (PDF extraction, question-answer parsing, string matching) while Bedrock orchestrates the workflow and presents results. This hybrid approach eliminates hallucination risk, handles edge cases like pre-filled questions automatically, and scales to grade hundreds of submissions reliably.

## What You'll Build

You'll build a multi-tool grading agent that orchestrates four specialized tools to grade PDF submissions accurately and reliably. The agent receives S3 paths for an answer key and student submission, calls `extract_answer_key` and `extract_student_answers` to parse both PDFs into structured dictionaries (question number → answer), then calls `compare_answers` to perform deterministic string matching and calculate scores. Bedrock handles workflow orchestration and result presentation, but the heavy lifting—text extraction and parsing—happens in deterministic Python code.

This architecture eliminates hallucination risk in data extraction, automatically handles edge cases like pre-filled example questions, and allows you to grade any test format by updating the parsing logic without retraining models.

```
User Prompt → Agent (Bedrock) → Tool Selection → Deterministic Parsing → Grading Results
                     ↓
          [extract_answer_key, extract_student_answers, compare_answers]
                     ↓
               PyMuPDF + Regex (reliable extraction)
```

| Component           | Purpose                                      | Approach |
|---------------------|----------------------------------------------|----------|
| Strands Agent       | Orchestrates tool calls, presents results    | LLM reasoning |
| Amazon Bedrock      | Workflow reasoning and formatting            | Natural language understanding |
| PyMuPDF Tools       | PDF text extraction (deterministic)          | Direct file processing |
| Parsing Logic       | Question-answer mapping (regex-based)        | Pattern matching |
| String Matching     | Answer comparison (case-insensitive)         | Deterministic comparison |

**Why this matters:** Deterministic tools handle data extraction and comparison reliably (no hallucination), while the agent focuses on workflow orchestration and intelligent result presentation. This separation makes the system accurate, maintainable, and scalable.

## Architecture Decision: When to Use Custom Tools vs. LLM Processing

A common question when building agents is: Why not just send the PDFs to the LLM and let it handle everything?

For grading, this creates reliability issues that compound at scale:

**Option 1: Pure LLM Processing**
```
→ Upload both PDFs to Bedrock
→ Prompt: "Grade this student submission against this answer key"
→ LLM extracts questions, parses answers, compares, returns score
```

**Problems:**

- **Hallucination risk**: LLMs can misread question numbers or answers from complex PDF layouts (especially multi-line answers, blocked sections, handwritten marks)
- **Inconsistency**: Same PDF processed twice might yield different results due to model non-determinism
- **Debugging difficulty**: When grading is wrong, you can't tell if it's parsing or comparison that failed
- **Maintenance burden**: Changing test formats requires prompt engineering and testing across edge cases

**Option 2: Hybrid Approach (This Playbook)**
```
→ Custom tools extract text (PyMuPDF)
→ Regex parses questions and answers deterministically
→ Python compares strings (case-insensitive matching)
→ Agent orchestrates workflow and formats results
```

**Benefits:**

- **Zero hallucination**: Parsing logic is deterministic and testable
- **Consistent results**: Same input always produces same output
- **Easy debugging**: Parsing errors are traceable through code, not prompt engineering
- **Maintainable**: Update regex patterns for new formats without retraining
- **Intelligent edge cases**: Agent still reasons about pre-filled questions, missing answers, feedback generation

**When to use each approach:**

| Scenario | Approach | Reason |
|----------|----------|--------|
| Structured data extraction (forms, tests, invoices) | Custom tools + agent orchestration | Deterministic, debuggable, accurate |
| Essay grading (subjective scoring) | LLM processing | Requires reasoning about content quality |
| Multiple-choice with printed answers | Custom tools | Pattern matching is sufficient |
| Open-ended questions (short answer) | Hybrid: extract with tools, score with LLM | Balance accuracy and flexibility |

For this grading agent, answer keys and student submissions follow known formats. The questions and correct answers don't change between submissions. This makes deterministic parsing the right choice—use tools for predictable tasks, let the agent handle orchestration, edge cases, and presentation.

## Prerequisites

* AWS account in `us-west-2` with permissions to create S3 buckets, Lambda functions, IAM roles, and layers.
* Amazon Bedrock access with `us.amazon.nova-pro-v1:0` enabled. Enable models in the [Bedrock console](https://console.aws.amazon.com/bedrock/) if needed.
* **Terraform ≥ v1.13.4** installed locally or in CloudShell.
* **AWS CLI v2** configured with appropriate credentials.
* **Python 3.12** (required for Lambda runtime). This guide uses `pip` to build the Lambda layer with platform-specific binaries for Linux x86_64.


## Step 1: Prepare Your Terraform Project

Create a directory for your Terraform project using the post slug:

```bash
mkdir -p ~/ai-pdf-grading-agent-strands-lambda
cd ~/ai-pdf-grading-agent-strands-lambda
```

💡 Tip: All files in this tutorial (Terraform configs, Lambda code, build scripts) are organized under the `ai-pdf-grading-agent-strands-lambda/` directory, matching the post slug. This keeps related resources grouped together.

The tutorial includes two sample PDF files for testing using a clear naming convention:
- **[question_and_answers.pdf](/media/images/2025/12/question_and_answers.pdf)**: Answer key with questions 1-20 and correct answers (teacher's copy)
- **[answers.pdf](/media/images/2025/12/answers.pdf)**: Student submission with answers to questions 4-20 (questions 1-3 are pre-filled examples)

Download these files to your project directory:

```bash
# Download the sample PDFs
curl -o question_and_answers.pdf https://brainyl.cloud/media/images/2025/12/question_and_answers.pdf
curl -o answers.pdf https://brainyl.cloud/media/images/2025/12/answers.pdf

# Verify downloads
ls -lh *.pdf
```

These PDFs demonstrate the parser's ability to extract structured data from real test formats and will be uploaded to S3 during deployment. The naming convention is self-documenting: `question_and_answers.pdf` contains the full answer key, while `answers.pdf` contains only student answers.

## Step 2: Create the Layer Build Script

The Lambda layer packages the Strands SDK, Strands tools, and PyMuPDF (for PDF text extraction). PyMuPDF correctly handles complex PDF layouts and prevents text concatenation issues that can occur with other libraries. The build script uses pip's `--platform` flag to install packages with Linux x86_64 binaries compatible with the Lambda runtime.

Create `build_layer.sh`:



```bash
#!/bin/bash
set -e

echo "Building Lambda layer..."

# Clean up any existing layer directory
rm -rf lambda_layer
mkdir -p lambda_layer/python

# Install packages with platform-specific binaries for Lambda (Linux x86_64)
# Use --platform to ensure compatibility with Lambda runtime
# PyMuPDF provides better text extraction than pypdf
pip install --target lambda_layer/python --no-cache-dir --upgrade \
    --platform manylinux2014_x86_64 \
    --only-binary=:all: \
    --python-version 3.12 \
    strands-agents \
    strands-agents-tools \
    PyMuPDF

# Remove boto3/botocore (Lambda runtime provides these)
rm -rf lambda_layer/python/boto3* lambda_layer/python/botocore* lambda_layer/python/s3transfer* 2>/dev/null || true

# Clean up unnecessary files
echo "Cleaning up unnecessary files..."
find lambda_layer/python -type d -name 'tests' -exec rm -rf {} + 2>/dev/null || true
find lambda_layer/python -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find lambda_layer/python -type f -name '*.pyc' -delete 2>/dev/null || true
find lambda_layer/python -type f -name '*.pyo' -delete 2>/dev/null || true

# Package the layer
echo "Packaging layer..."
cd lambda_layer
zip -r strands-pymupdf-layer.zip python -q
cd ..

echo "✅ Layer built successfully: lambda_layer/strands-pymupdf-layer.zip"
ls -lh lambda_layer/strands-pymupdf-layer.zip
```


Make it executable:

```bash
chmod +x build_layer.sh
```

## Step 3: Write the Lambda Handler with Multi-Tool Orchestration

Create the Lambda function code that defines the Strands agent and four specialized grading tools. Each tool has a clear responsibility in the workflow:

1. **`extract_pdf_text`**: Downloads a PDF from S3 and extracts selectable text using PyMuPDF. Returns raw text without interpretation.

2. **`extract_answer_key`**: Calls `extract_pdf_text` internally, then parses the text to build a dictionary mapping question numbers to expected answers (e.g., `{1: 'whom', 2: 'when', ...}`). Handles multiple formats: inline answers (`4. whose`), multi-line answers, and blocked answer sections after markers.

3. **`extract_student_answers`**: Calls `extract_pdf_text` for the student submission, then parses it using the answer key's question numbers as a reference. Returns a similar dictionary of student responses.

4. **`compare_answers`**: Takes S3 paths for both PDFs, calls the extraction tools internally, then performs deterministic string matching (case-insensitive) to calculate scores. Automatically detects pre-filled example questions (questions before the first student answer) and excludes them from grading. Returns detailed per-question results.

The agent orchestrates these tools based on a simple prompt: *"Grade the student submission at s3://bucket/answers.pdf using the answer key at s3://bucket/question_and_answers.pdf."* Bedrock figures out it needs to call `compare_answers` with those paths, and the tool handles the rest—keeping PDF parsing deterministic and reliable.

**Why this matters:** By keeping extraction and comparison logic in Python, you get deterministic, testable, debuggable behavior for the predictable parts of grading. The agent focuses on what LLMs do best—understanding intent, handling edge cases, and presenting results—while tools handle what code does best—reliable data processing.

Create `lambda_function.py`:



```python
import json
import os
import re
import boto3
import fitz  # PyMuPDF
from io import BytesIO
from strands import Agent, tool
from strands.models import BedrockModel

s3 = boto3.client("s3")
REGION = os.environ.get("AWS_REGION", "us-west-2")

def extract_text_pymupdf(pdf_bytes: bytes) -> str:
    """Extract text using PyMuPDF (superior quality)"""
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    text = ""
    for page in doc:
        text += page.get_text() + "\n"
    doc.close()
    return text

def parse_answer_key_text(text: str) -> dict:
    """
    Generic answer key parser - handles multiple formats.
    
    Formats supported:
    1. Same line: "4. whose"
    2. Separate lines: "4." followed by "whose"
    3. Blocked answers: Question numbers, then answer block after © Grammarism
    
    Returns: {1: 'whom', 2: 'when', ...}
    """
    answers = {}
    lines = [line.strip() for line in text.split('\n')]
    question_numbers = []
    
    # Pass 1: Extract inline answers and track all question numbers
    i = 0
    while i < len(lines):
        line = lines[i]
        
        # Try same-line format: "4. whose"
        match = re.match(r'^(\d{1,3})[\.\)\:]\s+(.+)$', line)
        if match:
            q_num = int(match.group(1))
            answer = match.group(2).strip().lower()
            question_numbers.append(q_num)
            # Only save if it doesn't look like question text
            if len(answer) < 50 and '_' not in answer:
                if q_num not in answers:
                    answers[q_num] = answer
            i += 1
            continue
        
        # Track standalone question numbers: "4."
        match = re.match(r'^(\d{1,3})[\.\)\:]$', line)
        if match:
            q_num = int(match.group(1))
            question_numbers.append(q_num)
            
            # Check if next line is an inline answer
            if i + 1 < len(lines):
                next_line = lines[i + 1].strip()
                skip_patterns = ['_', '©', 'grammarism', 'name:', 'test:', 'result:', 'date:']
                if (next_line and 
                    not re.match(r'^\d+[\.\)\:]', next_line) and
                    len(next_line) < 50 and
                    not any(p in next_line.lower() for p in skip_patterns)):
                    answer = next_line.lower()
                    if q_num not in answers:
                        answers[q_num] = answer
                    i += 2
                    continue
        
        i += 1
    
    # Pass 2: Extract blocked answers after © Grammarism
    unanswered_questions = sorted([q for q in question_numbers if q not in answers])
    
    if unanswered_questions:
        blocked_answers = []
        for i, line in enumerate(lines):
            if '© grammarism' in line.lower():
                # Skip "Name:" line if present
                j = i + 1
                while j < len(lines) and ('name:' in lines[j].lower() or not lines[j].strip()):
                    j += 1
                
                # Collect answers
                while j < len(lines):
                    potential_answer = lines[j].strip()
                    if not potential_answer:
                        j += 1
                        continue
                    
                    # Stop conditions
                    if (re.match(r'^\d+[\.\)\:]', potential_answer) or 
                        '©' in potential_answer or
                        len(potential_answer) > 50):
                        break
                    
                    blocked_answers.append(potential_answer.lower())
                    j += 1
        
        # Map blocked answers to unanswered questions
        for i, q_num in enumerate(unanswered_questions):
            if i < len(blocked_answers):
                answers[q_num] = blocked_answers[i]
    
    return answers

def parse_student_submission_text(text: str, answer_key: dict) -> dict:
    """
    Generic student submission parser.
    
    Tries multiple strategies:
    1. Numbered answers (most reliable): "4. whose"
    2. Sequential extraction (fallback): Maps to answer_key question numbers
    
    Args:
        text: Raw text from student PDF
        answer_key: Answer key dict for question number reference
    
    Returns: {4: 'whose', 5: 'when', ...}
    """
    lines = [line.strip() for line in text.split('\n')]
    
    # Strategy 1: Extract numbered answers
    answers = {}
    for line in lines:
        match = re.match(r'^(\d{1,3})[\.\)\:]\s+(.+)$', line)
        if match:
            q_num = int(match.group(1))
            answer = match.group(2).strip().lower()
            if q_num not in answers:
                answers[q_num] = answer
    
    if answers:
        return answers
    
    # Strategy 2: Sequential extraction (for unmarked answers)
    all_answers = []
    for i, line in enumerate(lines):
        if '© grammarism' in line.lower() or 'grammarism' in line:
            # Collect potential answers after marker
            for j in range(i+1, min(i+25, len(lines))):
                potential_answer = lines[j].strip()
                if not potential_answer:
                    continue
                
                # Skip headers
                if any(skip in potential_answer.lower() for skip in ['name:', 'test:', 'result:', 'date:']):
                    continue
                
                # Skip very long lines (likely question text)
                if len(potential_answer) > 100:
                    continue
                
                all_answers.append(potential_answer.lower())
                
                # Stop if we hit another marker
                if '©' in potential_answer or 'grammarism' in potential_answer:
                    break
    
    # Map sequential answers to question numbers from answer key
    question_nums = sorted(answer_key.keys())
    answers = {}
    for i, ans in enumerate(all_answers):
        if i < len(question_nums):
            q_num = question_nums[i]
            answers[q_num] = ans
    
    return answers

@tool
def extract_pdf_text(bucket: str, key: str) -> str:
    """
    Extract selectable text from a PDF stored in S3 using PyMuPDF.
    
    Args:
        bucket: S3 bucket name
        key: S3 object key (path to PDF)
    
    Returns:
        Extracted text from all pages
    """
    response = s3.get_object(Bucket=bucket, Key=key)
    pdf_content = response['Body'].read()
    return extract_text_pymupdf(pdf_content)

@tool
def extract_answer_key(bucket: str, key: str) -> dict:
    """
    Extract and parse the answer key from a PDF.
    
    Handles multiple formats:
    - Inline: "4. whose"
    - Multi-line: "4." followed by "whose"
    - Blocked: Question numbers, then answers after markers
    
    Args:
        bucket: S3 bucket name
        key: S3 object key for answer key PDF
    
    Returns:
        Dictionary mapping question numbers to expected answers
        Example: {1: 'whom', 2: 'when', 3: 'what', ...}
    """
    # Extract text from PDF
    text = extract_pdf_text(bucket, key)
    
    # Parse into structured format
    answer_key = parse_answer_key_text(text)
    
    return {
        "answer_key": answer_key,
        "total_questions": len(answer_key),
        "question_numbers": sorted(answer_key.keys())
    }


@tool
def extract_student_answers(
    bucket: str, 
    key: str,
    answer_key_bucket: str,
    answer_key_key: str
) -> dict:
    """
    Extract and parse student answers from a PDF.
    
    Internally fetches the answer key to determine question number mappings.
    Handles numbered and sequential answer formats.
    
    Args:
        bucket: S3 bucket name  
        key: S3 object key for student submission PDF
        answer_key_bucket: S3 bucket for answer key (needed for question reference)
        answer_key_key: S3 key for answer key PDF
    
    Returns:
        Dictionary mapping question numbers to student answers
        Example: {4: 'whose', 5: 'when', 6: 'which', ...}
    """
    # Extract text from both PDFs
    student_text = extract_pdf_text(bucket, key)
    answer_key_text = extract_pdf_text(answer_key_bucket, answer_key_key)
    
    # Parse answer key to get question numbers
    answer_key = parse_answer_key_text(answer_key_text)
    
    # Parse student answers (needs answer_key for question number reference)
    student_answers = parse_student_submission_text(student_text, answer_key)
    
    return {
        "student_answers": student_answers,
        "answered_questions": len(student_answers),
        "question_numbers": sorted(student_answers.keys())
    }


@tool
def analyze_question_coverage(answer_key: dict, student_answers: dict) -> dict:
    """
    Analyze which questions the student should be graded on.
    
    Detects patterns like:
    - Questions 1-3 missing, 4-20 present → Q1-3 likely pre-filled examples
    - Questions scattered missing → Student skipped those
    
    Args:
        answer_key: Dict from extract_answer_key tool
        student_answers: Dict from extract_student_answers tool
    
    Returns:
        Analysis of which questions to grade and which are pre-filled
    """
    # Extract the actual answer dicts (tools return wrapped format)
    if isinstance(answer_key, dict) and 'answer_key' in answer_key:
        answer_key = answer_key['answer_key']
    if isinstance(student_answers, dict) and 'student_answers' in student_answers:
        student_answers = student_answers['student_answers']
    
    all_questions = sorted(answer_key.keys())
    student_questions = sorted(student_answers.keys())
    
    if not student_questions:
        return {
            "questions_to_grade": [],
            "pre_filled_questions": [],
            "skipped_questions": all_questions,
            "analysis": "No student answers found"
        }
    
    # Find first and last student answer
    first_answered = student_questions[0]
    last_answered = student_questions[-1]
    
    # Questions before first answer are likely pre-filled examples
    pre_filled = [q for q in all_questions if q < first_answered]
    
    # Questions after first answer but not answered are skipped
    questions_in_range = [q for q in all_questions if first_answered <= q <= last_answered]
    skipped = [q for q in questions_in_range if q not in student_answers]
    
    # Questions to grade: what student was supposed to answer
    questions_to_grade = [q for q in all_questions if q >= first_answered]
    
    analysis = []
    if pre_filled:
        if len(pre_filled) == 1:
            analysis.append(f"Question {pre_filled[0]} is a pre-filled example (not graded)")
        else:
            analysis.append(f"Questions {pre_filled[0]}-{pre_filled[-1]} are pre-filled examples (not graded)")
    
    if skipped:
        analysis.append(f"Student skipped {len(skipped)} question(s) in their assigned range: {', '.join(map(str, skipped))}")
    
    if not skipped:
        analysis.append(f"Student attempted all assigned questions ({first_answered}-{last_answered})")
    else:
        analysis.append(f"Grading questions {first_answered}-{last_answered} ({len(questions_to_grade)} total)")
    
    return {
        "questions_to_grade": questions_to_grade,
        "pre_filled_questions": pre_filled,
        "skipped_questions": skipped,
        "student_answered": student_questions,
        "pre_filled_count": len(pre_filled),
        "skipped_count": len(skipped),
        "analysis": " | ".join(analysis)
    }


@tool
def compare_answers(
    answer_key_bucket: str,
    answer_key_key: str,
    student_bucket: str,
    student_key: str
) -> dict:
    """
    Compare student answers against the answer key with intelligent question detection.
    
    Performs deterministic string matching (case-insensitive).
    Automatically detects pre-filled questions by analyzing which questions 
    the student answered. Questions before the first student answer are excluded
    as pre-filled examples.
    
    Args:
        answer_key_bucket: S3 bucket for answer key
        answer_key_key: S3 key for answer key PDF
        student_bucket: S3 bucket for student submission
        student_key: S3 key for student PDF
    
    Returns:
        Grading results with score, percentage, per-question breakdown, and coverage info
    """
    # Extract and parse both PDFs
    answer_key_text = extract_pdf_text(answer_key_bucket, answer_key_key)
    student_text = extract_pdf_text(student_bucket, student_key)
    
    answer_key = parse_answer_key_text(answer_key_text)
    student_answers = parse_student_submission_text(student_text, answer_key)
    
    # Auto-detect grading scope
    all_questions = sorted(answer_key.keys())
    student_questions = sorted(student_answers.keys())
    
    if student_questions:
        # Questions before first student answer are pre-filled examples
        first_answered = student_questions[0]
        pre_filled = [q for q in all_questions if q < first_answered]
        # Only grade questions from first_answered onwards
        grading_scope = set([q for q in all_questions if q >= first_answered])
    else:
        # No student answers found
        pre_filled = []
        grading_scope = set(all_questions)
    
    results = []
    correct_count = 0
    attempted_count = 0
    
    # Grade each question in scope
    for q_num in sorted(grading_scope):
        expected = answer_key[q_num]
        
        if q_num in student_answers:
            # Student answered this question
            student = student_answers[q_num]
            is_correct = (expected == student)
            attempted_count += 1
            
            if is_correct:
                correct_count += 1
            
            results.append({
                "question": q_num,
                "student_answer": student,
                "expected_answer": expected,
                "correct": is_correct
            })
        else:
            # Student didn't answer (within grading scope)
            results.append({
                "question": q_num,
                "student_answer": None,
                "expected_answer": expected,
                "correct": False,
                "note": "Not attempted"
            })
    
    # Calculate final metrics
    total = attempted_count  # Only count what was attempted
    percent = round((correct_count / total) * 100, 1) if total else 0.0
    
    # Build coverage note (top-level for agent clarity)
    pre_filled_note = None
    if pre_filled:
        if len(pre_filled) == 1:
            pre_filled_note = f"Question {pre_filled[0]} was a pre-filled example and not graded"
        else:
            pre_filled_note = f"Questions {pre_filled[0]}-{pre_filled[-1]} were pre-filled examples and not graded"
    
    result = {
        "score": correct_count,
        "total": total,
        "percent": percent,
        "attempted_questions": attempted_count,
        "total_questions_in_scope": len(grading_scope),
        "total_questions_in_key": len(answer_key),
        "results": sorted(results, key=lambda x: x["question"])
    }
    
    # Add pre-filled note at top level if present
    if pre_filled_note:
        result["pre_filled_note"] = pre_filled_note
    
    return result

# initialize Bedrock model
model = BedrockModel(
    model_id="us.amazon.nova-pro-v1:0",
    temperature=0.0,  # deterministic for grading
)

# create agent with grading tools
agent = Agent(
    model=model,
    tools=[extract_pdf_text, extract_answer_key, extract_student_answers, compare_answers],
    system_prompt=(
        "You are an experienced grading assistant. When asked to grade a student submission:\n\n"
        "Use the compare_answers tool with the S3 paths for both the answer key and student submission.\n"
        "This tool will:\n"
        "- Extract and parse both PDFs\n"
        "- Automatically detect pre-filled example questions (questions before the first student answer)\n"
        "- Grade only the questions the student was supposed to answer\n"
        "- Return detailed results with scores and per-question breakdown\n\n"
        "Present the results clearly:\n"
        "- State the overall score and percentage\n"
        "- If the result has a 'pre_filled_note' field, include it EXACTLY as provided\n"
        "- List some correct answers\n"
        "- List incorrect answers with what was expected\n"
        "- Provide brief constructive feedback\n\n"
        "Example format:\n"
        "**Score:** 9/17 (52.9%)\n\n"
        "**Note:** [Use exact pre_filled_note from results if present]\n\n"
        "**Correct:** Q5, Q7, Q8, Q11, Q13, Q14, Q15, Q18, Q19\n\n"
        "**Incorrect:**\n"
        "- Q4: answered 'whose', expected 'who'\n"
        "- Q6: answered 'which', expected 'whose'\n"
        "...\n\n"
        "Be fair, clear, and helpful in your assessment."
    )
)

def lambda_handler(event, context):
    """
    Lambda handler for PDF grading agent.
    
    The agent orchestrates three tools to complete grading:
    1. extract_answer_key - Parse the answer key PDF
    2. extract_student_answers - Parse the student submission PDF
    3. compare_answers - Compare and calculate score
    
    Input event format:
    {
        "student_bucket": "pdf-grading-agent-386452075078",
        "student_key": "answers.pdf",
        "answer_key_bucket": "pdf-grading-agent-386452075078",
        "answer_key_key": "question_and_answers.pdf"
    }
    
    Where:
    - question_and_answers.pdf = Answer key (questions + correct answers)
    - answers.pdf = Student submission (their answers only)
    
    Returns:
    {
        "statusCode": 200,
        "body": {
            "score": 9,
            "total": 17,
            "percent": 52.9,
            "attempted_questions": 17,
            "total_questions_in_key": 20,
            "results": [...]
        }
    }
    """
    try:
        # extract parameters
        student_bucket = event.get("student_bucket")
        student_key = event.get("student_key")
        answer_key_bucket = event.get("answer_key_bucket")
        answer_key_key = event.get("answer_key_key")
        
        # validate inputs
        if not all([student_bucket, student_key, answer_key_bucket, answer_key_key]):
            return {
                "statusCode": 400,
                "body": json.dumps({
                    "error": "Missing required parameters. Provide student_bucket, student_key, answer_key_bucket, answer_key_key."
                })
            }
        
        # construct prompt for agent
        prompt = (
            f"Grade the student submission at s3://{student_bucket}/{student_key} "
            f"using the answer key at s3://{answer_key_bucket}/{answer_key_key}."
        )
        
        # invoke agent
        response = agent(prompt)
        
        # return agent response
        result = response.content if hasattr(response, 'content') else str(response)
        
        return {
            "statusCode": 200,
            "body": result
        }
    
    except Exception as e:
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)})
        }
```


This handler defines four Strands tools and an agent that orchestrates the grading workflow:

**Tool Architecture:**

- **`extract_pdf_text(bucket, key)`**: Base tool for PDF text extraction. Uses PyMuPDF to handle complex layouts without text concatenation issues. Returns raw text.
- **`extract_answer_key(bucket, key)`**: Parses answer key text into structured format `{question_number: expected_answer}`. Handles inline answers (`4. whose`), multi-line formats, and blocked answer sections.
- **`extract_student_answers(bucket, key, answer_key_bucket, answer_key_key)`**: Parses student submission using the answer key's question numbers as reference. Handles numbered and sequential answer formats.
- **`compare_answers(answer_key_bucket, answer_key_key, student_bucket, student_key)`**: Orchestrates the full grading workflow. Calls extraction tools internally, performs deterministic string matching, detects pre-filled questions, calculates scores.

**Parsing Logic:** The parsers use regex patterns to extract question numbers and answers without hardcoded word lists. The answer key parser looks for "number. answer" patterns (e.g., `4. whose`) across multiple lines. The student submission parser finds answer blocks after markers like "© Grammarism" and maps them to question numbers. This generic approach works with any test format—WH-questions, multiple choice, fill-in-the-blank, etc.

**Deterministic Processing:** Notice that all four tools use `@tool` decorator but contain zero LLM calls internally. PyMuPDF extraction, regex parsing, and string comparison happen in pure Python. The agent uses Bedrock only for understanding the grading request and formatting results—keeping the heavy lifting deterministic and testable.

## Step 4: Write Terraform Configuration

Create the Terraform configuration to provision the S3 bucket, Lambda layer, Lambda function, and IAM roles. Terraform will automatically build the Lambda layer using the script from Step 2.

Create `main.tf`:



```terraform
terraform {
  required_version = ">= 1.13.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# S3 bucket for PDFs
resource "aws_s3_bucket" "grading_bucket" {
  bucket = "pdf-grading-agent-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "PDF Grading Agent Bucket"
    Environment = "demo"
  }
  
  # Allow bucket to be destroyed even if it contains objects
  force_destroy = true
}

# Upload sample PDFs (naming convention)
# - question_and_answers.pdf = Answer key (questions + correct answers)
# - answers.pdf = Student submission (their answers only)
resource "aws_s3_object" "answer_key" {
  bucket = aws_s3_bucket.grading_bucket.id
  key    = "question_and_answers.pdf"
  source = "${path.module}/question_and_answers.pdf"
  etag   = filemd5("${path.module}/question_and_answers.pdf")
}

resource "aws_s3_object" "student_submission" {
  bucket = aws_s3_bucket.grading_bucket.id
  key    = "answers.pdf"
  source = "${path.module}/answers.pdf"
  etag   = filemd5("${path.module}/answers.pdf")
}

# Upload Lambda layer to S3
resource "aws_s3_object" "lambda_layer" {
  bucket = aws_s3_bucket.grading_bucket.id
  key    = "layers/strands-pymupdf-layer.zip"
  source = "${path.module}/lambda_layer/strands-pymupdf-layer.zip"
  etag   = filemd5("${path.module}/lambda_layer/strands-pymupdf-layer.zip")
}

# Lambda layer
resource "aws_lambda_layer_version" "strands_pymupdf" {
  layer_name          = "strands-pymupdf-py312"
  s3_bucket           = aws_s3_bucket.grading_bucket.id
  s3_key              = aws_s3_object.lambda_layer.key
  compatible_runtimes = ["python3.12"]
  
  description = "Strands SDK, Strands Tools, and PyMuPDF for PDF grading"
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name_prefix = "pdf-grading-agent-lambda-"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM policy for Lambda
resource "aws_iam_role_policy" "lambda_policy" {
  name_prefix = "pdf-grading-agent-policy-"
  role        = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.function_name}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.grading_bucket.arn,
          "${aws_s3_bucket.grading_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/us.amazon.nova-pro-v1:0",
          "arn:aws:bedrock:*::foundation-model/amazon.nova-pro-v1:0",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*"
        ]
      }
    ]
  })
}

# Lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "grading_agent" {
  function_name = var.function_name
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 512
  
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  
  layers = [aws_lambda_layer_version.strands_pymupdf.arn]
  
  environment {
    variables = {
      DEFAULT_REGION       = var.aws_region
      BYPASS_TOOL_CONSENT  = "true"
    }
  }
  
  tags = {
    Name        = "PDF Grading Agent"
    Environment = "demo"
  }
}

# Data sources
data "aws_caller_identity" "current" {}

# Outputs
output "bucket_name" {
  description = "S3 bucket name for PDFs"
  value       = aws_s3_bucket.grading_bucket.id
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.grading_agent.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.grading_agent.arn
}

output "test_command" {
  description = "AWS CLI command to test the function"
  value       = <<-EOT
    aws lambda invoke \
      --function-name ${aws_lambda_function.grading_agent.function_name} \
      --payload '{"student_bucket":"${aws_s3_bucket.grading_bucket.id}","student_key":"answers.pdf","answer_key_bucket":"${aws_s3_bucket.grading_bucket.id}","answer_key_key":"question_and_answers.pdf"}' \
      --region ${var.aws_region} \
      response.json && cat response.json
  EOT
}
```


Create `variables.tf`:



```terraform
variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-west-2"
}

variable "function_name" {
  description = "Lambda function name"
  type        = string
  default     = "pdf-grading-agent"
}
```


## Step 5: Deploy with Terraform

<!--
```bash
# QA: Copy PDF files from media directory
WORKSPACE_ROOT="$(pwd | sed 's|/blog_qa/qa_files/.*||')"
cp "$WORKSPACE_ROOT/content/posts/media/images/2025/12/answers.pdf" ./
cp "$WORKSPACE_ROOT/content/posts/media/images/2025/12/question_and_answers.pdf" ./
```
-->

Make the build script executable and build the Lambda layer:



```bash
chmod +x build_layer.sh
./build_layer.sh
```


Now initialize Terraform, validate the configuration, and apply:


```bash
terraform init
terraform validate
terraform plan
terraform apply -auto-approve
```


Terraform provisions the S3 bucket, uploads the Lambda layer and actual PDF files (answer key and student submission), creates the IAM role with least-privilege permissions, and deploys the Lambda function. The entire process takes 2–3 minutes.

✅ Result: Terraform outputs the bucket name and Lambda function name with real PDF files uploaded to S3.

## Step 6: Test the Grading Agent

Use the AWS CLI to invoke the Lambda function with the sample PDFs. The agent receives S3 paths, calls `compare_answers`, which internally orchestrates the extraction and parsing tools, then returns a detailed score report.

```bash
# Get your AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Construct the bucket name (deterministic based on account ID)
BUCKET="pdf-grading-agent-$ACCOUNT_ID"

# Invoke the Lambda function to grade the student submission
aws lambda invoke \
  --function-name pdf-grading-agent \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"student_bucket\":\"$BUCKET\",\"student_key\":\"answers.pdf\",\"answer_key_bucket\":\"$BUCKET\",\"answer_key_key\":\"question_and_answers.pdf\"}" \
  --region us-west-2 \
  response.json

# View the grading results
cat response.json
```

**What happens internally:**

1. Agent receives prompt: *"Grade the student submission at s3://bucket/answers.pdf using the answer key at s3://bucket/question_and_answers.pdf"*
2. Bedrock decides to call `compare_answers` tool with both S3 paths
3. Tool calls `extract_answer_key` → extracts 20 questions, maps to expected answers
4. Tool calls `extract_student_answers` → extracts student responses for Q4-20
5. Tool detects Q1-3 are pre-filled examples (student didn't answer them)
6. Tool compares Q4-20 using case-insensitive string matching
7. Agent receives results, formats output with Bedrock, returns to user

Expected response:

```
**Score:** 9/17 (52.9%)

**Note:** Questions 1-3 were pre-filled examples and not graded

**Correct:** Q5, Q7, Q8, Q11, Q13, Q14, Q15, Q18, Q19

**Incorrect:**
- Q4: answered 'whose', expected 'who'
- Q6: answered 'which', expected 'whose'
- Q9: answered 'which', expected 'when'
- Q10: answered 'why', expected 'where'
- Q12: answered 'where', expected 'whom'
- Q16: answered 'which', expected 'what'
- Q17: answered 'where', expected 'which'
- Q20: answered 'what', expected 'where'

**Feedback:**
You did well on several questions, but there are areas where you need improvement. Pay attention to the differences between 'who' and 'whose', 'which' and 'whose', 'which' and 'when', 'why' and 'where', 'where' and 'whom', 'which' and 'what', 'where' and 'which', and 'what' and 'where'. Review these concepts to improve your performance.
```

The student scored 9 out of 17 (52.9%) on this WH-questions test. The agent correctly detected that questions 1-3 were pre-filled examples (the student started answering at question 4) and excluded them from grading. This intelligent behavior—detecting grading scope based on what the student actually answered—demonstrates how agents can make decisions without explicit instructions for every edge case.

```bash
aws logs tail /aws/lambda/pdf-grading-agent --follow --region us-west-2
```

## Validation

Verify the agent and tools work end-to-end:

1. **Check S3 uploads**: Confirm PDFs are in the bucket:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 ls s3://pdf-grading-agent-$ACCOUNT_ID/ --human-readable
```

You should see `answers.pdf` (student submission) and `question_and_answers.pdf` (answer key).

2. **Verify Lambda layer**: List layers attached to the function to confirm Strands SDK and PyMuPDF are available:

```bash
aws lambda get-function --function-name pdf-grading-agent --region us-west-2 \
  --query 'Configuration.Layers[*].Arn'
```

3. **Test tool call sequence**: Check CloudWatch Logs to see the agent's tool orchestration:

```bash
aws logs tail /aws/lambda/pdf-grading-agent --since 5m --region us-west-2
```

Look for log entries showing:
- Agent receives grading prompt
- Calls `compare_answers` with S3 paths
- Tool internally calls `extract_answer_key` and `extract_student_answers`
- Returns structured grading results

4. **Test with different PDFs**: Upload new student submissions to S3, then invoke the function with updated parameters:

```bash
# Upload a new student submission
aws s3 cp student2.pdf s3://pdf-grading-agent-$ACCOUNT_ID/answers.pdf

# Grade it
aws lambda invoke \
  --function-name pdf-grading-agent \
  --payload "{\"student_bucket\":\"pdf-grading-agent-$ACCOUNT_ID\",\"student_key\":\"answers.pdf\",\"answer_key_bucket\":\"pdf-grading-agent-$ACCOUNT_ID\",\"answer_key_key\":\"question_and_answers.pdf\"}" \
  --region us-west-2 \
  response.json && cat response.json
```

5. **Verify Bedrock integration**: Check CloudTrail for `InvokeModel` events to confirm the agent is calling Bedrock for orchestration:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=InvokeModel \
  --max-results 5 \
  --region us-west-2
```

✅ Result: You should see successful Lambda invocations, accurate grading results with intelligent pre-filled question detection, and detailed per-question breakdowns with constructive feedback.

## Cleanup

Destroy all resources with Terraform:


```bash
terraform destroy -auto-approve
```


This removes the S3 bucket (including all PDFs), Lambda function, Lambda layer, IAM role, and CloudWatch log groups. The bucket uses `force_destroy = true`, so it will be deleted even if it contains objects.

💡 Tip: The S3 bucket name is deterministic: `pdf-grading-agent-{your-account-id}`. This makes it easy to identify and manage. If you run the tutorial multiple times, it will reuse the same bucket name.

## Production Notes

**Performance and scalability:**

* **Batch processing**: For end-of-semester grading (100+ submissions), invoke the Lambda function in parallel with AWS Step Functions or EventBridge Scheduler rather than sequential API calls. Process 50–100 submissions concurrently.
* **Answer key caching**: Parse answer keys once and cache the result when grading multiple submissions against the same test. Store parsed results in Lambda's `/tmp` directory or ElastiCache.
* **Optimize parsing logic**: Profile the regex parsing to identify bottlenecks if processing thousands of submissions. Consider pre-compiling regex patterns or using faster parsing libraries for specific formats.

**IAM and security:**

* **IAM tightening**: Scope S3 permissions to specific prefixes (e.g., `question_and_answers.pdf` and `answers.pdf` patterns) instead of the entire bucket. Limit Bedrock permissions to the specific model ARN (`arn:aws:bedrock:us-west-2::foundation-model/us.amazon.nova-pro-v1:0`).
* **S3 bucket encryption**: Enable SSE-S3 or SSE-KMS for PDFs containing student data. This is often required for FERPA compliance in educational settings.
* **VPC deployment**: If processing sensitive student data, run Lambda in a VPC with VPC endpoints for S3 and Bedrock (no internet gateway required).

**Error handling and reliability:**

* **Retry logic**: Add exponential backoff for transient S3 and Bedrock failures. Use the AWS SDK's built-in retry configuration.
* **Malformed PDF handling**: Catch PyMuPDF exceptions when PDFs are corrupted or password-protected. Return clear error messages to users rather than generic 500 errors.
* **Parsing validation**: If parsing returns fewer than expected questions, flag the submission for manual review rather than auto-grading with incomplete data.

**Scaling and performance:**

* **Lambda concurrency**: Lambda automatically scales, but check Bedrock service quotas. Request increases if grading a lot of students simultaneously.
* **Answer key caching**: For repeated grading against the same answer key, cache the parsed result in Lambda's `/tmp` directory or ElastiCache to avoid redundant parsing.
* **Multi-assignment support**: Extend the naming convention to support multiple assignments: `assignments/{assignment-id}/question_and_answers.pdf` and `assignments/{assignment-id}/submissions/{student-id}.pdf`.

**Monitoring and observability:**

* **CloudWatch alarms**: Alert on Lambda errors, duration > 30 seconds, Bedrock throttling, or unusual grading patterns (e.g., all scores zero, no questions extracted).
* **X-Ray tracing**: Enable X-Ray to visualize tool call sequences and identify bottlenecks in the grading workflow.
* **Custom metrics**: Log parsing success rates, question extraction accuracy, grading duration per submission, and edge cases detected (pre-filled questions, missing answers) for ongoing monitoring and improvement.

## Key Takeaways

* **Multi-tool orchestration makes grading reliable and scalable.** Deterministic parsing (PyMuPDF + regex) handles data extraction without hallucination, while Bedrock handles workflow orchestration, edge cases, and result presentation. This separation produces consistent, debuggable results.
* **Hybrid architectures balance accuracy and intelligence.** Use custom tools for predictable tasks (PDF extraction, string matching, data validation) where determinism matters, and let agents handle reasoning tasks (workflow decisions, result formatting, edge case detection).
* **Tool composition enables complex workflows with simple interfaces.** The `compare_answers` tool internally calls `extract_answer_key` and `extract_student_answers`, which call `extract_pdf_text`. The agent doesn't need to know this—it just calls one tool and gets comprehensive results.
* **Deterministic tools eliminate hallucination risk.** PyMuPDF extracts text exactly as it appears. Regex parsing matches patterns reliably. String comparison is boolean. No LLM guessing means no grading errors, no inconsistency between runs, and no debugging prompt engineering.
* **Agents handle edge cases without explicit instructions.** The grading agent detected pre-filled questions (Q1-3) by analyzing which questions the student answered, then excluded them from scoring—no hardcoded rules, just reasoning from the data structure.
* **This pattern scales beyond grading.** Invoice extraction (OCR tool + parsing tool + validation tool), resume screening (PDF tool + entity extraction tool + scoring tool), contract analysis (extraction tool + clause detection tool + risk assessment tool)—any document workflow where accuracy and scalability matter benefits from this separation of concerns.

### Related Reading

**Building on this series:**

* Start with [Turn Your First Lambda Into a Strands Agent](./lambda-to-strands-agent.md) to understand the basics of Strands agents with a single-tool translation example.
* This post extends that pattern to multi-tool orchestration—four specialized tools working together to handle complex document processing reliably at scale.

**AWS and Terraform resources:**

* Explore Terraform best practices in the <a href="https://developer.hashicorp.com/terraform/tutorials" target="_blank" rel="noopener">HashiCorp Terraform tutorials</a>.
* Understand Lambda layers and packaging in the <a href="https://docs.aws.amazon.com/lambda/latest/dg/configuration-layers.html" target="_blank" rel="noopener">AWS Lambda developer guide</a>.
* Learn about least-privilege IAM policies in the <a href="https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html" target="_blank" rel="noopener">AWS IAM best practices guide</a>.

**Tool development:**

* Learn about PyMuPDF capabilities for reliable PDF text extraction in the <a href="https://pymupdf.readthedocs.io/" target="_blank" rel="noopener">PyMuPDF documentation</a>.
* Explore Strands' built-in tool ecosystem in the <a href="https://strandsagents.com/" target="_blank" rel="noopener">Strands documentation</a>.
* Understand Amazon Bedrock model selection and pricing in the <a href="https://docs.aws.amazon.com/bedrock/" target="_blank" rel="noopener">Amazon Bedrock user guide</a>.

**Production considerations:**

* For multi-agent workflows and advanced orchestration patterns, see the <a href="https://docs.aws.amazon.com/bedrock-agentcore/" target="_blank" rel="noopener">Amazon Bedrock AgentCore user guide</a>.
* Consider adding custom tools for domain-specific grading logic (handwriting recognition via Textract, formula validation for math tests, plagiarism detection via embeddings comparison).
