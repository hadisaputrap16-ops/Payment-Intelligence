# Generator dokumentasi Payment Intelligence

Semua isi ada di `content.js` (satu sumber); `build_html.js`, `build_pdf.js`, `build_pptx.js` menghasilkan tiga format dari sumber yang sama, `diagram.js` berisi geometri diagram bersama.

```bash
npm install pptxgenjs@3.12.0 pdfkit@0.15.0 @napi-rs/canvas@0.1.65 fast-xml-parser@4.5.1
node build_html.js ../Payment_Intelligence_Dokumentasi.html
node build_pdf.js  ../Payment_Intelligence_Dokumentasi.pdf          # butuh font DejaVu (/usr/share/fonts/truetype/dejavu)
node build_pptx.js ../Payment_Intelligence_Dokumentasi.pptx /tmp/pi-slide   # arg 2 = prefix gambar preview QA
node validate.js   ../Payment_Intelligence_Dokumentasi.pptx
```
`build_pptx.js` memakai `apply_theme.js` dari skill pptx; ubah path `require` di baris atas bila lokasinya berbeda.
