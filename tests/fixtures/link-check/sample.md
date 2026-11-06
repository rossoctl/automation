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

Parenthesized URL: [wiki](https://extract.example/wiki/Foo_(bar))
Bare with parens: https://extract.example/bare_(paren) and trailing period https://extract.example/period_(paren).
Prose parens: (https://extract.example/paren-prose) and (see https://extract.example/paren-prose2).

- outer item
  - nested item: [nested](https://extract.example/nested-list)
    four-space prose inside the nested item: https://extract.example/list-item-prose
- loose item

  continuation after a blank at 2 spaces: https://extract.example/loose-list-continuation

        eight-space code inside the item (must skip): https://extract.example/list-item-code-skip

Paragraph line
    lazy continuation with https://extract.example/paragraph-continuation
