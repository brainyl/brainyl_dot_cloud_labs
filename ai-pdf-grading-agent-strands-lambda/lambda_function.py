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
    
    Input event format (v1):
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