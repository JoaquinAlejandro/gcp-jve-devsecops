from flask import Flask
import os

app = Flask(__name__)

@app.route("/")
def home():
    return {"status": "ok", "mensaje": "Hola desde Cloud Run"}

@app.route("/health")
def health():
    return {"status": "healthy"}

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)