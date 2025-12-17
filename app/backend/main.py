from fastapi import FastAPI
from pydantic import BaseModel
import os
import psycopg2
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()

# Permitir que el frontend (cualquier origen) consulte a la API
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # En producción real pondrías el dominio del ALB
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuración DB (variables de entorno)
DB_HOST = os.getenv("DB_HOST", "db")
DB_NAME = os.getenv("DB_NAME", "taskdb")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASS = os.getenv("DB_PASS", "postgres")

class Task(BaseModel):
    name: str

@app.get("/")
def read_root():
    return {"message": "API funcionando v1"}

@app.get("/tasks")
def get_tasks():
    # En producción usarías un ORM, esto es raw para simplicidad
    conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASS)
    cur = conn.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS tasks (id serial PRIMARY KEY, name varchar);")
    cur.execute("SELECT name FROM tasks;")
    tasks = [r[0] for r in cur.fetchall()]
    conn.close()
    return {"tasks": tasks}

@app.post("/tasks")
def add_task(task: Task):
    conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASS)
    cur = conn.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS tasks (id serial PRIMARY KEY, name varchar);")
    cur.execute("INSERT INTO tasks (name) VALUES (%s)", (task.name,))
    conn.commit()
    conn.close()
    return {"status": "ok"}