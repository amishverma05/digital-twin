from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import os
from dotenv import load_dotenv
from typing import Optional, List, Dict
import json
import uuid
from datetime import datetime
from google import genai
from context import prompt

# Load environment variables
load_dotenv()

# Initialize Gemini client (uses API key from env automatically)
client = genai.Client()
print("GEMINI_API_KEY present:", bool(os.getenv("GEMINI_API_KEY")))

app = FastAPI()

# Configure CORS
origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# Memory storage configuration
USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

if USE_S3:
    import boto3
    from botocore.exceptions import ClientError
    s3_client = boto3.client("s3")


class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None


class ChatResponse(BaseModel):
    response: str
    session_id: str


def get_memory_path(session_id: str) -> str:
    return f"{session_id}.json"


def load_conversation(session_id: str) -> List[Dict]:
    if USE_S3:
        try:
            response = s3_client.get_object(Bucket=S3_BUCKET, Key=get_memory_path(session_id))
            return json.loads(response["Body"].read().decode("utf-8"))
        except Exception:
            return []
    else:
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        if os.path.exists(file_path):
            with open(file_path, "r") as f:
                return json.load(f)
        return []


def save_conversation(session_id: str, messages: List[Dict]):
    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=get_memory_path(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )
    else:
        os.makedirs(MEMORY_DIR, exist_ok=True)
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        with open(file_path, "w") as f:
            json.dump(messages, f, indent=2)


def call_gemini(conversation: List[Dict], user_message: str) -> str:
    """
    Gemini text generation with memory
    """

    prompt_lines = []

    # System prompt
    prompt_lines.append(prompt())

    # Conversation history (last 10 exchanges)
    for msg in conversation[-20:]:
        role = "User" if msg["role"] == "user" else "Assistant"
        prompt_lines.append(f"{role}: {msg['content']}")

    # Current user message
    prompt_lines.append(f"User: {user_message}")

    final_prompt = "\n".join(prompt_lines)

    try:
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=final_prompt
        )
        return response.text

    except Exception as e:
        print("Gemini error:", e)
        raise HTTPException(status_code=500, detail="Gemini invocation failed")


@app.get("/")
async def root():
    return {
        "message": "AI Digital Twin API (Powered by Gemini)",
        "provider": "Google Gemini"
    }


@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "provider": "gemini"
    }


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        session_id = request.session_id or str(uuid.uuid4())
        conversation = load_conversation(session_id)

        assistant_response = call_gemini(conversation, request.message)

        conversation.append({
            "role": "user",
            "content": request.message,
            "timestamp": datetime.now().isoformat()
        })
        conversation.append({
            "role": "assistant",
            "content": assistant_response,
            "timestamp": datetime.now().isoformat()
        })

        save_conversation(session_id, conversation)

        return ChatResponse(
            response=assistant_response,
            session_id=session_id
        )

    except HTTPException:
        raise
    except Exception as e:
        print(f"Error in chat endpoint: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/conversation/{session_id}")
async def get_conversation(session_id: str):
    try:
        return {
            "session_id": session_id,
            "messages": load_conversation(session_id)
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
