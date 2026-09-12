# 나의 봉사동기 프로필

전국청소년자원봉사대회 교육 프로그램을 위한 학생용 봉사동기 활동입니다.

## 참여 흐름

참여 코드 확인 → 이름·학교 또는 소속 입력과 수집 안내 확인 → 검사 안내 → 30문항 응답 → 결과 리포트 순서로 진행합니다. 결과를 본 뒤 응답을 수정하면 같은 제출 건에 최신 결과를 다시 저장합니다.

화면, 문항, 채점 로직과 일러스트는 `index.html` 하나에 포함되어 있습니다. 빌드나 패키지 설치는 필요하지 않지만, 참여 코드 확인과 결과 저장에는 인터넷 연결이 필요합니다.

## 데이터 처리

앱은 이름, 학교 또는 소속, 30개 응답과 여섯 동기 결과를 Supabase로 전송합니다. 브라우저에는 진행 중인 상태와 짧은 유효기간의 참여 토큰을 `sessionStorage`에만 보관합니다.

Supabase의 `volunteer_submissions` 테이블은 Row Level Security를 강제로 적용하고 `anon`·`authenticated` 역할의 접근을 제거했습니다. 공개 웹앱은 테이블에 직접 접근하지 않으며, `volunteer-profile` Edge Function이 참여 코드를 확인하고 서버에서 점수를 다시 계산한 뒤 저장합니다. 관리자 키와 실제 참여 코드는 저장소에 포함하지 않습니다.

운영자는 Supabase Dashboard의 Table Editor에서 원본 `volunteer_submissions`를 확인할 수 있습니다. Excel용 `volunteer_submissions_export` 뷰에는 이름·소속, 개별 점수·순위와 문항 응답 `q01`~`q30`을 각각의 열로 펼쳐 두었습니다. 이 뷰를 CSV로 내보내면 Excel에서 바로 분석할 수 있습니다.

점수 열의 뜻은 `score_p` 보호, `score_v` 가치, `score_c` 진로, `score_s` 사회, `score_u` 이해, `score_e` 성장입니다. 순위 열도 같은 알파벳을 사용합니다. 문항 응답은 `1`~`5` 또는 `unsure`로 저장됩니다. 검사 버전 2에서는 `unsure` 원응답과 개수를 그대로 보존하면서 점수 계산에만 0을 사용합니다.

## 결과 해석

Clary et al.(1998)의 Volunteer Functions Inventory(VFI)를 참고한 교육용 활동입니다. 이 한국어 교육판 자체의 신뢰도와 타당도를 별도로 검증한 것은 아닙니다. 각 동기의 다섯 문항을 합해 5로 나눈 평균을 표시하며, 교육용으로 추가한 ‘아직 잘 모르겠어요’는 0점으로 반영합니다. 결과 화면에서 해당 문항을 다시 살펴보고 응답을 바꿀 수 있습니다.

## 구성

- `index.html`: GitHub Pages용 단일 웹앱
- `supabase/migrations/202609120001_volunteer_collection.sql`: 비공개 수집 테이블과 원자적 저장 함수
- `supabase/migrations/202609120002_unsure_zero_scoring.sql`: 0점 결과를 허용하는 점수 제약 변경
- `supabase/functions/volunteer-profile/index.ts`: 참여 확인, 입력 검증, 서버 채점과 저장
- `supabase/config.toml`: Edge Function의 배포 설정

실제 참여 코드의 해시는 배포 시 비공개 데이터베이스에 별도로 등록합니다.

점수 규칙을 바꾸는 배포는 데이터베이스 마이그레이션 → Edge Function → `index.html` 순서로 진행합니다. 새 화면이 먼저 공개되어 아직 바뀌지 않은 서버 규칙과 충돌하는 일을 막기 위한 순서입니다.

## GitHub Pages

이 저장소의 `main` 브랜치 루트(`/`)를 게시 소스로 사용합니다. `.nojekyll` 파일로 정적 HTML을 그대로 제공합니다.

배포 주소: https://seedcoop.github.io/KBvolunteertest/
