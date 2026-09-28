# 파일패널 (FilePanel)

화면 가장자리에 책갈피처럼 붙어 있다가, 필요할 때만 꺼내 쓰는 **macOS 파일 변환기**입니다.

탭을 누르고 파일을 끌어다 놓으면 형식은 자동으로 인식됩니다. 결과 형식만 골라 변환하세요.

## 주요 기능

- **어디서든 꺼내 쓰는 패널** — 화면 왼쪽/오른쪽 가장자리의 탭, 또는 메뉴 막대 아이콘에서 열기
- **자동 형식 인식** — 확장자가 아니라 파일 내용으로 실제 형식을 판별 (이름은 `.png`인데 내용은 WebP인 파일도 정확히)
- **가능한 형식만 제안** — 올린 파일로 만들 수 있는 결과 형식만 메뉴에 표시
- **드래그 앤 드롭** — 탭이나 메뉴 막대 아이콘 위로 파일을 끌고 오면 자동으로 열림
- **Mac다운 디자인** — 라이트/다크 모드, 강조 색, VoiceOver 지원
- **개인정보 보호** — 모든 변환은 기기 안에서만. 네트워크 연결·데이터 수집 없음, App Sandbox 적용

## 지원 형식

| 구분 | 받는 형식 | 결과 형식 |
|---|---|---|
| 이미지 | PNG, JPEG, HEIC, HEIF, AVIF, WebP, JPEG XL, TIFF, GIF, BMP | PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP |
| 전문가용 | PSD, JPEG 2000, OpenEXR, TGA, HDR, SGI, PBM, PICT | PSD, JPEG 2000, OpenEXR, TGA |
| 카메라 RAW | Canon, Nikon, Sony, Fujifilm, Panasonic, Olympus, Leica, DNG 등 | — |
| 아이콘 | ICO, ICNS | ICO, ICNS (규격 크기 자동 생성) |
| 문서 | PDF, DOCX, DOC, RTF, ODT, TXT | PDF, DOCX, DOC, RTF, ODT, TXT, HTML, 페이지별 PNG/JPEG |

> 워드 문서 변환은 macOS 내장 문서 엔진을 사용해 머리글·바닥글, 각주, 복잡한 표 등 일부 레이아웃이 원본과 다를 수 있습니다.

## 요구 사항

- macOS 26 이상
- Apple Silicon / Intel Mac

## 빌드

1. Xcode 27 이상에서 `filepanel.xcodeproj`를 엽니다.
2. `filepanel` 스킴을 선택하고 실행(⌘R)합니다.

외부 라이브러리 없이 Apple 프레임워크(SwiftUI, AppKit, ImageIO, PDFKit)만 사용합니다.

## 개인정보 처리방침 · 지원

- [개인정보 처리방침](https://carryhoon.github.io/filepanel/privacy/)
- [지원 페이지](https://carryhoon.github.io/filepanel/)
- 문의 · 버그 제보: [GitHub Issues](https://github.com/carryHoon/filepanel/issues)

---

Copyright © 2026 파일패널. All rights reserved.
