# claude-gogo-kit

다른 PC(다른 Claude 계정)에 Claude Code 기본 세팅을 **한 줄 프롬프트로** 까는 키트예요.
대화를 `/gogo` 로 시작하면 세팅을 점검하고, 모자란 건 스스로 고친 뒤, 옵시디언에서 지난 맥락을 불러와 시작해요.

| 깔리는 것 | 하는 일 |
|---|---|
| **caveman** 플러그인 ([JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)) | 답을 짧게 → 토큰 절약 (중요한 설명·경고는 또박또박) |
| **카파시 원문 지침** ([원문 65줄](https://github.com/multica-ai/andrej-karpathy-skills/blob/main/CLAUDE.md)) | `~/.claude/CLAUDE.md` 맨 위에 원문 그대로 (고정된 판, 해시 확인). 아래에 이 PC용 규칙(한국어·옵시디언·디스코드) |
| **/karpathy** 스킬 | "카파시라면?" / "더 좋은 방법 있어?" → 표준·대안 비교 후 추천 하나 |
| **옵시디언 보관함** ([Karpathy LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)) | Claude가 쓰고 관리하는 누적 기억: 운영 규칙·목차·작업 기록·PC 폴더 지도·사람용 사용법. 모든 프로젝트에서 읽기·쓰기 허용 |
| **디스코드 봇** | 결정이 필요한 질문(추천안 파란 버튼) · 결과물 피드백(👍/👎/✏️) · 알림 · 채널 만들기/정리 |
| **바로가기 창** (`Ctrl+Shift+F`, AutoHotkey v2) | 어디서든 단축키 → 동그란 바로가기 아이콘(빈 목록에서 시작, ＋로 추가) + 화면 오른쪽 위 **오늘의 퀘스트**(누르면 체크, 매일 자동 초기화) + 위쪽 가운데 **달력**. 퀘스트·일정은 옵시디언 `내 일정/` 노트 두 개. **로컬 서버**: 꺼진 `localhost` 바로가기를 누르면 창 없이 켜고 열림 · 왼쪽 위 「서버 N개」 = 켜진 서버 목록(메모리·안 쓴 시간) → 오래 안 쓴 것 끄기 |
| **/gogo** 스킬 + `gogo.mjs check --fix` | 위 전부 점검 → 자동 수리 → 맥락 불러오기 → 세션 시작 |

**안 들어가는 것**: 메인 PC의 개인정보·토큰·주소·폴더 경로, 메인 PC를 조작하는 기능. 키트에는 코드와 빈 양식만 있고, 디스코드 토큰은 설치한 PC의 `~/.gogo/.env` 에만 저장돼요.

---

## 1. 미리 준비 (PC 앞에서 한 번)

1. **Claude 계정**: Remote Control은 **Pro / Max 구독**이 필요해요 (Team·Enterprise는 관리자가 Remote Control을 켜야 함).
2. **Claude Code 설치** (PowerShell, 관리자 권한 X): `irm https://claude.ai/install.ps1 | iex` → `claude` 실행 → 로그인.
3. **Remote Control 켜기**: 그 PC에서 `claude remote-control` 실행 → 처음 한 번 `Enable Remote Control? (y/n)` 에 **y** (원격에선 대신 누를 수 없음). 이 창을 켜 두면 휴대폰·claude.ai/code에서 그 PC의 새 세션을 열 수 있어요.

## 2. 원라인 프롬프트 (Remote Control로 그 PC 세션에 붙여 넣기)

```
https://raw.githubusercontent.com/subbyscenter/claude-gogo-kit/main/SETUP.md 를 읽고 그대로 따라 이 PC를 세팅해줘. PC 이름: 회사PC
```

설치가 끝나면 **새 세션**을 열고 `/gogo`. (caveman은 새 세션부터 켜져요.)
같은 프롬프트를 다시 보내면 = 최신 키트로 업데이트 + 수리. (키트 저장소가 내려가 있으면 업데이트는 X — 그래도 그 PC의 `/gogo` 점검·수리는 그대로 돼요.)

## 3. 디스코드 봇 만들기 (설치해 주는 사람이, 아무 PC에서)

⚠️ **메인 PC 봇을 재사용하지 말고 새로 만드세요.** 메인 봇 토큰이 그 PC에 들어가면 메인 서버가 그 PC에서 보여요.

1. **서버 만들기** — 디스코드 왼쪽 **＋** → 직접 만들기 → 나와 친구들을 위한 서버 → 이름(예: `클로드 작업실`).
   그 PC 사용자를 초대한 뒤 원하면 서버 설정 → 멤버 → 그 사람 ⋯ → **소유권 이전**.
2. **앱 만들기** — https://discord.com/developers/applications → **New Application** → 이름(예: `클로드 봇`).
   General Information의 **Application ID** 를 복사해 둬요.
3. **Installation** 탭 → Install Link를 **None** 으로 (이걸 먼저 해야 4번의 Public Bot을 끌 수 있어요).
4. **Bot** 탭 (`https://discord.com/developers/applications/<Application ID>/bot`):

   | 옵션 | 설정 | 이유 |
   |---|---|---|
   | Public Bot | **끄기** | 만든 사람만 초대할 수 있게 |
   | Requires OAuth2 Code Grant | 끄기 | 안 씀 |
   | **Message Content Intent** | **켜기** | 답장으로 쓴 글을 봇이 읽음 (꺼져 있으면 @멘션한 답장만 읽힘) |
   | Server Members Intent | 끄기 (켜도 무방) | 안 씀 |
   | Presence Intent | 끄기 (켜도 무방) | 안 씀 |
   | Reset Token → **Copy** | 토큰 복사 | 한 번만 보여요. 3번 끝나고 그 PC Claude에게 전달 |

   **"그냥 다 켜도 돼?"** → Intent 3개는 다 켜도 동작에 문제 X (봇이 100개 서버 미만이면 심사도 X). 그래도 필요한 건 Message Content 하나뿐이라 그것만 켜는 걸 추천.
5. **서버에 초대** — 아래 주소의 `<Application ID>` 만 바꿔 열고, 1번 서버 선택 → 승인:
   ```
   https://discord.com/oauth2/authorize?client_id=<Application ID>&scope=bot&permissions=117840
   ```
   `117840` = 채널 보기 · **채널 관리**(채널 만들기·정리) · 메시지 보내기 · 링크 첨부 · 파일 첨부 · 메시지 기록 보기 · 반응 추가, 이렇게 7개.
   **"권한도 그냥 다 켜도 돼?"** → *Administrator* 하나만 체크해도 똑같이 동작해요. 개인 서버라 큰 문제는 없지만, 토큰이 새면 서버를 통째로 지울 수 있는 권한이라 7개를 추천해요.
6. **토큰 전달** — 그 PC 세션에 "디코 봇 토큰: `<토큰>`" 이라고 보내면 Claude가
   `node ~/claude-gogo-kit/gogo.mjs discord-setup --token <토큰>` 으로 저장하고(화면에 다시 안 보임) 봇을 켜요.
   봇이 서버를 하나만 알면 서버 ID도 자동으로 찾아요. 토큰이 샌 것 같으면 Bot 탭에서 Reset Token → 다시 6번.

봇이 켜지면 서버에 **「클로드」 카테고리**와 `#답변대기` `#결과물-피드백` `#알림` 이 생기고, 업무별(`--topic 회계`)로 쓰면 「회계」 카테고리가 자동으로 생겨요. 정리하면 「보관함」 카테고리로 옮겨져요(삭제는 분명히 말할 때만).

## 4. 그 PC에서 쓰는 법

| 이렇게 말하면 | Claude가 하는 일 |
|---|---|
| `/gogo` (대화 처음에) | 세팅 점검·수리 + 지난번 하던 일 불러오기 |
| "저장해줘" | 다시 쓸 내용을 옵시디언에 정리 (어디에 저장했는지 한 줄 보고) |
| "옵시디언 참조" / "이어서 하자" | 지난 맥락 요약 |
| "카파시라면?" / "더 좋은 방법 있어?" | 더 나은 방법을 알아보고 하나 추천 |
| "디코에 ○○ 채널 만들어줘" / "디코 정리해줘" | 채널 만들기·이름 바꾸기·옮기기·보관함 정리 |
| (Claude가 결정이 필요할 때) | 디스코드 #답변대기에 버튼 질문 → 누르면 바로 전달 |
| `Ctrl+Shift+F` (어디서든) | 바로가기 창 + 오늘의 퀘스트 + 달력. 한 번 더 누르거나 Esc = 닫기 |
| "바로가기에 ○○ 넣어줘" / "퀘스트에 ○○ 추가" / "12월 3일에 ○○ 일정 넣어줘" | Claude가 바로가기 목록·퀘스트·일정 노트를 고침 (창은 다음에 열 때 반영) |

사람용 자세한 안내는 보관함의 `AI-Sessions/wiki/guides/obsidian-guide.md`.

## 5. 문제가 생기면

- 그 PC에서 `/gogo` → 점검 표의 「할 일」을 따라가면 돼요.
- 봇: `node ~/claude-gogo-kit/gogo.mjs bot status|start|stop` · 로그 `~/.gogo/data/bot.log`
- 회사 네트워크가 discord.com을 막으면 봇은 동작하지 않아요 (표에 「연결 실패」).
- 봇 자동 시작 끄기: `shell:startup` 폴더의 `gogo-discord-bot.vbs` 삭제.
- 바로가기 창이 안 뜸: `/gogo` → 「바로가기 창」 줄. 회사 보안 프로그램이 AutoHotkey를 막으면 IT 담당자에게 허용 부탁. 끄기 = 작업 표시줄 오른쪽 초록 H 아이콘 → 끄기, 자동 시작 끄기 = `shell:startup` 의 `gogo-desktop.vbs` 삭제.
- `Ctrl+Shift+F` 는 PC 전체 단축키라 다른 프로그램의 같은 키(옵시디언 「내용으로 찾기」, 워드 글꼴 창 등)를 가려요.

## 파일

| 파일 | 역할 |
|---|---|
| `setup.ps1` | 설치 시작점 (Node·MinGit 없으면 사용자 폴더에 → 키트 받기 → `gogo.mjs install`) |
| `gogo.mjs` | install · check [--fix] · discord-setup · bot start/stop/status |
| `claude/CLAUDE.kit.md` | 카파시 원문 아래에 붙는 이 PC 규칙 (`{{VAULT}}` 등은 설치 때 채워짐) |
| `claude/skills/` | `/gogo`, `/karpathy` |
| `vault/` | 보관함 양식 (없는 파일만 만들고, 있는 파일은 절대 덮어쓰지 않음) |
| `discord/` | `bot.mjs`(상주 봇) · `ask.mjs`(질문·결과물·알림·채널) · `common.mjs` |
| `desktop/` | 바로가기 창 (AutoHotkey v2): `desktop.ahk`(단축키·트레이) · `popup.ahk`(창·퀘스트·달력) · `lib.ahk`(목록·노트 읽고 쓰기) · `servers.ahk`+`servers.mjs`(로컬 서버 켜기·세기·끄기, 창 없이) · `test.ahk`(자가 시험). 사용자 목록·아이콘·서버 기록은 `~/.gogo/desktop/` 에 |
