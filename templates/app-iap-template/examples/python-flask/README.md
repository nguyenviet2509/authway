# Flask + gunicorn — IAP Setup

Workflow setup Flask app để chạy phía sau oauth2-proxy.

## File structure giả định

```
my-flask-app/
├── requirements.txt
├── app.py                  # Flask() instance ở đây
└── templates/
```

Nếu app structure khác (vd `wsgi.py`, factory pattern `create_app()`), update CMD trong Dockerfile.

## 1. Before-request handler đọc IAP header

```python
# app.py
from flask import Flask, g, request, abort, jsonify

app = Flask(__name__)

# Health endpoint — đặt TRƯỚC before_request handler để skip auth check
@app.route("/health")
def health():
    return jsonify(ok=True)

@app.before_request
def authenticate():
    # Skip auth cho health + static
    if request.path in ("/health",) or request.path.startswith("/static/"):
        return None

    email = request.headers.get("X-Auth-Request-Email")
    if not email:
        abort(401)
    g.user_email = email
    g.user_sub = request.headers.get("X-Auth-Request-User")      # UUID immutable
    g.user_name = request.headers.get("X-Auth-Request-Preferred-Username")

@app.route("/")
def home():
    return f"Hello {g.user_name or g.user_email}"
```

## 2. Trust proxy headers

Flask mặc định không trust `X-Forwarded-*`. Wrap WSGI:

```python
from werkzeug.middleware.proxy_fix import ProxyFix
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)
```

Cần thiết khi:
- App generate URL dùng `request.url_root` → phải biết scheme HTTPS
- Log IP client → phải đọc `X-Forwarded-For` thay vì IP Traefik

## 3. Factory pattern variant

```python
# app/__init__.py
def create_app():
    app = Flask(__name__)
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    @app.before_request
    def authenticate():
        # ... như trên
        pass

    from .routes import bp
    app.register_blueprint(bp)
    return app
```

Dockerfile CMD đổi thành:
```dockerfile
CMD ["gunicorn", "app:create_app()", "--bind", "0.0.0.0:3000", ...]
```

## 4. Flask-Login → bỏ

Nếu app đang dùng Flask-Login:

```bash
pip uninstall flask-login flask-security
```

Code thay đổi:
- Bỏ `LoginManager`, `@login_required` decorator
- Bỏ `current_user.is_authenticated` check
- Thay bằng `g.user_email` (đã set trong before_request)

Nếu cần `@login_required` semantics (vd skip protect 1 route):

```python
def login_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not g.get("user_email"):
            abort(401)
        return f(*args, **kwargs)
    return wrapper
```

Nhưng thường không cần vì `before_request` đã chặn rồi.

## 5. Copy Dockerfile + requirements + .dockerignore

```bash
cp ./Dockerfile ~/my-flask-app/
cp ./.dockerignore ~/my-flask-app/
cp ./requirements.txt.example ~/my-flask-app/requirements.txt
# Edit thêm deps app cần
```

Sửa Dockerfile nếu cần:
- Entry không phải `app:app` → đổi CMD `gunicorn <module>:<var>`
- Factory pattern → CMD `gunicorn "app:create_app()"`

## 6. Build + push

```bash
cd ~/my-flask-app
docker build -t ghcr.io/team/my-flask-app:v1.0.0 .

# Test local
docker run -p 3000:3000 ghcr.io/team/my-flask-app:v1.0.0
curl http://localhost:3000/health
curl http://localhost:3000/   # → 401
curl http://localhost:3000/ -H "X-Auth-Request-Email: test@example.com"
# → "Hello test@example.com"

docker push ghcr.io/team/my-flask-app:v1.0.0
```

## 7. Deploy với template

```dotenv
# .env trong template
APP_HOSTNAME=my-flask-app.company.com
APP_IMAGE=ghcr.io/team/my-flask-app:v1.0.0
APP_PORT=3000
```

```bash
docker compose pull && docker compose up -d
```

## Special case: Flask-SQLAlchemy + auto-provision user

```python
from flask_sqlalchemy import SQLAlchemy
db = SQLAlchemy(app)

class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String, unique=True, nullable=False)
    zitadel_subject = db.Column(db.String, unique=True, nullable=False)
    name = db.Column(db.String)

@app.before_request
def authenticate():
    if request.path.startswith(("/health", "/static")):
        return None
    email = request.headers.get("X-Auth-Request-Email")
    sub = request.headers.get("X-Auth-Request-User")
    if not email:
        abort(401)
    # Bind theo sub immutable
    user = User.query.filter_by(zitadel_subject=sub).first()
    if user is None:
        user = User(email=email, zitadel_subject=sub,
                    name=request.headers.get("X-Auth-Request-Preferred-Username"))
        db.session.add(user)
        db.session.commit()
    g.user = user
```

## Troubleshooting

| Triệu chứng | Fix |
|---|---|
| `gunicorn: command not found` | Pip install path không có trong PATH. Verify Dockerfile `ENV PATH=/home/app/.local/bin:$PATH` |
| `werkzeug.routing.exceptions.NotFound` cho `/oauth2/sign_out` | Flask không cần handle — oauth2-proxy bắt request trước. Nếu thấy 404 thì verify oauth2-proxy đang chạy |
| `redirect_uri` chuyển HTTP thay vì HTTPS | Thiếu `ProxyFix` middleware — thêm vào WSGI |
| Health endpoint bị 401 | `before_request` chạy trước route — skip path `/health` ngay đầu handler |
| Session cookie conflict với oauth2-proxy cookie | Flask `SECRET_KEY` riêng, không liên quan oauth2-proxy. OK để dùng song song |
