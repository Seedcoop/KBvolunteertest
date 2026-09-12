# 나의 봉사동기 프로필

전국청소년자원봉사대회 교육 프로그램을 위한 학생용 봉사동기 활동입니다.

## 참여 흐름

참여 코드 확인 → 이름·학교 또는 소속 입력과 수집 안내 확인 → 검사 안내 → 30문항 응답 → 결과 리포트 순서로 진행합니다. 결과를 본 뒤 응답을 수정하면 같은 제출 건에 최신 결과를 다시 저장합니다.

화면, 문항, 채점 로직과 일러스트는 `index.html` 하나에 포함되어 있습니다. 빌드나 패키지 설치는 필요하지 않지만, 참여 코드 확인과 결과 저장에는 인터넷 연결이 필요합니다.

## 데이터 처리

앱은 이름, 학교 또는 소속, 30개 응답과 여섯 동기 결과를 Supabase로 전송합니다. 브라우저에는 진행 중인 상태와 짧은 유효기간의 참여 토큰을 `sessionStorage`에만 보관합니다.

Supabase의 `volunteer_submissions` 테이블은 Row Level Security를 강제로 적용하고 `anon`·`authenticated` 역할의 접근을 제거했습니다. 공개 웹앱은 테이블에 직접 접근하지 않으며, `volunteer-profile` Edge Function이 참여 코드를 확인하고 서버에서 점수를 다시 계산한 뒤 저장합니다. 관리자 키와 실제 참여 코드는 저장소에 포함하지 않습니다.

운영자는 Supabase Dashboard의 Table Editor에서 이름·소속, 개별 점수·순위, 전체 응답 JSON을 확인하고 CSV로 내보낼 수 있습니다.

## 결과 해석

Clary et al.(1998)의 Volunteer Functions Inventory(VFI)를 참고한 교육용 활동입니다. 이 한국어 교육판 자체의 신뢰도와 타당도를 별도로 검증한 것은 아닙니다. 각 동기의 다섯 문항에 모두 수치로 응답하면 평균을 표시하며, ‘아직 잘 모르겠어요’는 점수에서 제외하고 해당 동기를 ‘생각 중’으로 표시합니다.

## 구성

- `index.html`: GitHub Pages용 단일 웹앱
- `supabase/migrations/202609120001_volunteer_collection.sql`: 비공개 수집 테이블과 원자적 저장 함수
- `supabase/functions/volunteer-profile/index.ts`: 참여 확인, 입력 검증, 서버 채점과 저장
- `supabase/config.toml`: Edge Function의 배포 설정

실제 참여 코드의 해시는 배포 시 비공개 데이터베이스에 별도로 등록합니다.

## GitHub Pages

이 저장소의 `main` 브랜치 루트(`/`)를 게시 소스로 사용합니다. `.nojekyll` 파일로 정적 HTML을 그대로 제공합니다.

배포 주소: https://seedcoop.github.io/KBvolunteertest/
