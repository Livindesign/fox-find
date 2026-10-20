# Product artwork

`icon.png` is the existing Fox Find product icon.
`hero.png` is an art-directed illustration based on the 0.8.6 native interface,
created with MangceAI. It uses fictional sample filenames and a tilted, exploded
frosted-glass composition to present the interface. It is not a literal screenshot
or a performance benchmark. The original fox brand mark is unchanged.

`screenshots/` contains native DEBUG renders of 0.0.1 build 41 in English and Chinese.
All six entries, their sizes/dates and the virtual `/Projects` directory are fictional.
No user's index, files, image thumbnails or desktop were captured. Generate them with
`python3 scripts/demo-screenshots.py` after building the pinned runtime. The list, grid
and actions come from actual AppKit views; offscreen captures use the stable opaque
snapshot backing instead of sampling the desktop behind the glass.

Conversation renders use fictional local records as well. Collection renders, when included, use the test fixture only. The hero remains an illustration; current behavior is shown in the build 41 native renders below it.
