# Claude Usage Bar

macOS 메뉴바에 claude.ai 구독 한도(5시간 세션, 7일 주간)의 **남은 양**을 보여주는 작은 네이티브 앱.

- 메뉴바: 잔량에 맞는 Clawd 게이지 아이콘 + 세션 잔량 퍼센트 (예: `73%`)
- 클릭: 세션, 주간, 모델별 주간 한도의 잔량 막대와 리셋까지 남은 시간, 새로고침, 로그인 시 실행, 종료

## 고지: 비공식 API

이 앱은 공식 문서에 없는 엔드포인트(`https://api.anthropic.com/api/oauth/usage`)를 사용한다.
언제든 응답 형식이 바뀌거나 막힐 수 있고, 사용이 약관상 허용되는지는 확인하지 않았다.
앱은 응답에서 필요한 값만 꺼내고 모르는 필드는 무시하지만, 형식이 크게 바뀌면 값이 표시되지 않을 수 있다.
Anthropic과 무관한 개인 도구다.

## 전제 조건

- Apple Silicon Mac, macOS 13 이상
- Swift 5.9 이상 (Command Line Tools 15 이상이면 된다. Xcode 불필요). 확인한 버전은 Swift 6.3.3이며, 5.9 미만은 시험하지 않았다.
  Swift 6 언어 모드로 빌드하려면 `Package.swift`의 `swiftLanguageVersions: [.v5]`를 지우고 `swift-tools-version`을 6.0으로 올린다(코드는 두 모드에서 모두 오류 없이 빌드된다).
- **Claude Code가 설치되어 있고 구독 계정으로 로그인되어 있어야 한다.**
  이 앱에는 자체 로그인이 없고, Claude Code가 macOS 키체인에 저장한 OAuth 토큰(`Claude Code-credentials`)을 빌려 쓴다.
  키체인에서 못 읽으면 `~/.claude/.credentials.json`을 읽는다.

## 빌드와 실행

```bash
./Scripts/bundle.sh
open build/ClaudeUsageBar.app
```

`bundle.sh`는 `swift build -c release`, `.app` 조립, ad-hoc 코드 서명(`codesign --sign -`)까지 한 번에 한다.
Dock에는 아이콘이 뜨지 않는다(`LSUIElement`).
개발 중 바이너리를 직접 실행할 때는 `swift build` 후 `.build/debug/ClaudeUsageBar`를 실행한다.

### 첫 실행 시 키체인 허용

처음 토큰을 읽을 때 키체인 접근 팝업이 한 번 뜬다. **"항상 허용"**을 선택한다.
토큰은 앱이 아니라 `/usr/bin/security`를 통해 읽기 때문에, ad-hoc 서명 앱을 다시 빌드해도 허용이 무효가 되지 않는다.

### 로그인 시 실행

패널의 "로그인 시 실행" 토글은 `SMAppService`를 쓴다. 앱을 `/Applications`로 옮긴 뒤 켜는 것을 권장한다.

## 동작

| 항목 | 값 |
|---|---|
| 조회 주기 | 180초 (앱 시작 직후 한 번 + 이후 180초마다) |
| 429 응답 | `Retry-After`와 현재 백오프 중 긴 쪽만큼 대기. 백오프는 300초에서 시작해 연속 429마다 2배, 최대 1800초. 첫 성공 시 초기화 |
| 429 백오프 중 | 수동 새로고침 포함 어떤 호출도 하지 않는다 |
| 그 외 오류 | 180초 주기로 재시도, 마지막 성공 값은 계속 표시 |
| 토큰 만료/없음 | API를 호출하지 않고 180초마다 토큰만 다시 읽는다 |
| 잠자기 복귀 | 예정 시각이 지났으면 바로 한 번 조회 |

- 토큰은 매 조회 직전에 새로 읽고, 로그나 파일에 남기지 않는다. 앱은 refresh token으로 토큰을 갱신하지 않는다.
- 토큰이 만료되면 터미널에서 `claude`를 한 번 실행하면 Claude Code가 갱신한다.
- 같은 요청 제한을 나눠 쓰므로 앱(또는 같은 API를 쓰는 다른 위젯)을 여러 개 동시에 실행하지 않는다.

### 메뉴바 표시

| 상태 | 표시 |
|---|---|
| 로딩 | 흐린 아이콘 + `…` |
| 정상 | 잔량 아이콘 + `73%` |
| 요청 제한, 오프라인/기타 오류 | 마지막 값 유지 + 뒤에 `!` (예: `73%!`) |
| 토큰 만료, 로그인 필요, 값 없음 | 에러 아이콘 + `?` |

`resets_at`이 이미 지난 한도는 사용량 0으로 계산한다.

## 아이콘 교체

아이콘은 `Resources/icons/`의 SVG를 그대로 쓴다(색과 모양을 코드에서 바꾸지 않는다).

- `icon-<숫자>.svg`: 잔량 단계별 아이콘. 잔량에 **가장 가까운 숫자**의 파일이 표시된다(동률이면 낮은 쪽). 폴더를 스캔하므로 단계를 늘리거나 줄여도 코드 수정이 필요 없다.
- `icon-error.svg`: 에러 상태 아이콘. 없으면 마지막 아이콘을 알파 40%로 쓴다.
- 높이는 메뉴바 18pt에 맞추고 가로세로 비율은 SVG의 viewBox를 따른다.

파일을 바꾼 뒤 `./Scripts/bundle.sh`로 다시 빌드한다. AppKit이 일부 SVG 기능(필터, CSS 스타일, 마스크 등)을 못 그릴 수 있으니 렌더링 결과를 확인한다.

```bash
.build/debug/ClaudeUsageBar --render-icons /tmp/icons   # 모든 아이콘을 PNG(높이 512px)와 확인용 sheet.png로 저장
```

## 앱 아이콘

Finder와 로그인 항목에 보이는 앱 아이콘은 `Resources/AppIcon.icns`다(`Info.plist`의 `CFBundleIconFile`이 가리킨다). 메뉴바 아이콘과는 별개다.
원본은 `Resources/app-icon.svg`이고, 크기별 PNG(16~1024px)로 `iconset`을 만들어 `iconutil -c icns <이름>.iconset -o Resources/AppIcon.icns`로 변환한다. 교체한 뒤 `./Scripts/bundle.sh`로 다시 빌드한다.

## 테스트용 실행 인자

| 인자 | 설명 |
|---|---|
| `--mock <사용률>` | API를 호출하지 않고 해당 세션 사용률로 표시 (`--mock 27` → 잔량 73%) |
| `--mock-error <expired\|login\|ratelimit\|offline>` | 각 오류 상태 확인. `--mock`과 함께 쓰면 마지막 값이 유지되는 경우를 볼 수 있다 |
| `--render-icons <dir>` | 아이콘을 AppKit으로 렌더링해 PNG로 저장 |
| `--check-token` | 토큰 상태(유효/만료/없음, 출처, 남은 시간)만 출력한다. 토큰 값은 출력하지 않는다 |
| `--api-url <url>` | 조회 주소를 로컬 서버(`127.0.0.1`, `localhost`, `::1`)로 바꾼다. 테스트용 |

`Fixtures/usage_sample.json`은 실제 응답에서 파싱에 필요한 구조만 남긴 샘플이다(금액과 사용 내역은 제거).

## 메모리

`ps -o rss=` 결과: mock 모드 **72~77MB**, 실제 모드(첫 조회 후, 패널 닫힘) **약 81~88MB**. 목표였던 30MB에는 못 미친다.
같은 프로세스의 실제 물리 메모리(`footprint`, `vmmap -summary`)는 mock 모드 약 14MB, 실제 모드 약 16~26MB다. RSS에는 SwiftUI/AppKit 등 시스템 프레임워크의 공유 페이지가 포함되어 크게 나온다.
패널을 처음 열 때 물리 메모리가 일시적으로 100MB 안팎까지 올랐다가 닫으면 20MB대로 돌아온다(측정: 최대 약 102MB → 26MB, 30초간 안정).

## 프로젝트 구조

```
Package.swift
Sources/ClaudeUsageBar/
  App.swift            @main, MenuBarExtra, 실행 인자, 메뉴바 라벨
  UsageStore.swift     상태, 폴링 루프, 백오프 적용
  UsageAPI.swift       엔드포인트 호출, 응답 해석, 백오프 정책, User-Agent
  Credentials.swift    토큰 읽기, 만료 검사
  IconProvider.swift   잔량별 SVG 선택/로드/캐시, --render-icons
  PopoverView.swift    클릭 시 패널
Resources/Info.plist, Resources/icons/ (메뉴바), Resources/AppIcon.icns, Resources/app-icon.svg (앱 아이콘)
Fixtures/usage_sample.json
Scripts/bundle.sh
```

## 아트워크

`Resources/icons/`의 Clawd 아이콘과 앱 아이콘(`AppIcon.icns`, `app-icon.svg`)은 사용자가 제공한 파일이다. 저장소를 공개하기 전에 아트워크의 사용 권리를 먼저 확인할 것.
