# Sample markdown for extraction golden tests

Inline link: [docs](https://extract.example/inline)
Image: ![alt](https://extract.example/image.png)
Reference style elsewhere.

[ref]: https://extract.example/reference

Autolink: <https://extract.example/autolink>
Bare: https://extract.example/bare

```bash
# fenced — must be skipped
curl https://extract.example/fenced-skip
```

Inline code `https://extract.example/inline-code-skip` must be skipped.

    https://extract.example/indented-skip

HTML in markdown: <a href="https://extract.example/html-href">x</a>
<img src="https://extract.example/html-src">
<code><a href="https://extract.example/code-skip">no</a></code>
<pre><a href="https://extract.example/pre-skip">no</a></pre>
