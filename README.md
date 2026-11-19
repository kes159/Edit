# AltSource Studio

[AltStudio](https://altstudio.app/)의 AltSource 편집 흐름을 참고해 만든 독립형 SwiftUI iOS 앱입니다. AltStore의 [Make a Source 규격](https://faq.altstore.io/developers/make-a-source)에 맞는 JSON을 작성합니다.

## 기능

- 소스 기본 정보, 이미지 URL, 색상, 링크, 추천 앱 편집
- 앱과 버전, iPhone/iPad 스크린샷, 권한, Patreon 정보 편집
- 뉴스 항목 편집
- 기존 AltSource JSON 가져오기, 실시간 JSON 미리보기, 파일로 저장
- 필수 입력 항목과 중복 식별자 확인
- 작업 내용 기기 내 자동 저장
- iPad의 넓은 화면에서는 사이드바와 편집 화면을 나란히 표시하고, 좁은 창에서는 탭 화면으로 전환

## 사용법

1. **소스** 탭에서 이름을 입력합니다.
2. **앱** 탭에서 앱과 최소 하나의 버전을 추가합니다. 다운로드 URL은 게시된 IPA 또는 ADP 파일을 가리켜야 합니다. 크기는 바이트 단위입니다.
3. 필요하면 **뉴스**를 추가합니다.
4. **JSON** 탭에서 검증 메시지를 확인하고 **JSON 저장**을 누릅니다. 기존 JSON은 같은 탭의 **가져오기**에서 열 수 있습니다.

이 앱은 JSON 파일을 생성합니다. 생성한 JSON과 실제 IPA/ADP는 사용자가 별도로 호스팅해야 AltStore 소스로 배포할 수 있습니다.

## 빌드와 설치

- Xcode에서 `AltSourceStudio.xcodeproj`를 엽니다.
- 배포 대상: iOS 17 이상.
- 제공된 IPA는 코드 서명 및 프로비저닝이 없는 빌드입니다. AltStore 등에서 기기용으로 서명해 설치하거나 Xcode에서 자신의 개발 팀을 선택해 다시 빌드하세요.
- 터미널에서는 `./scripts/build-ipa.sh`로 서명되지 않은 IPA를 `build/AltSourceStudio.ipa`에 만들 수 있습니다.

## 범위

AltStudio 웹사이트의 IPA/ADP 자동 스캔과 온라인 이미지 업로드는 포함하지 않았습니다. 해당 정보는 편집 화면에서 직접 입력합니다. 가져온 JSON 중 이 앱이 지원하지 않는 확장 필드는 내보낼 때 유지되지 않을 수 있으므로 원본 파일을 보관하세요.
