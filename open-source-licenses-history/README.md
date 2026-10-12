# The history of open source licenses: the laptop scan and the sources

Companion to the video **The History of Open Source Licenses**.
In GitHub's 2015 count, MIT was the most used license. The video asks a different question: what is inside the system you actually run?
[count-licenses.py](count-licenses.py) counts the license families of the packages installed on a Debian or Ubuntu machine.

## Run it

Needs Debian or Ubuntu and Python 3. No packages to install, no root. It only reads files under `/usr/share/doc`.

```bash
python3 count-licenses.py            # the count used in the video
python3 count-licenses.py --strict   # a stricter count, see "Where it is rough"
```

## Expected output

My laptop, Ubuntu 24.04.4 LTS, 2026-10-08. This is the output shown in the video:

```
packages with a license file: 2447
       gpl:  1639  67.0%
permissive:  1197  48.9%
       mit:   742  30.3%
      both:   898  36.7%
  unparsed:   354  14.5%
```

So: two out of three packages mention a GPL-family license, about half mention a permissive one, more than a third mention both.
Your numbers depend on what you have installed. A server will look different from a desktop.

## How the counting works

- Every Debian package ships a `/usr/share/doc/<package>/copyright` file. The script reads all of them.
- It collects every `License:` field in the file and searches the short names:
  `GPL` counts as gpl; `MIT`, `Expat`, `BSD`, `Apache`, `ISC` or `Zlib` counts as permissive; `MIT` or `Expat` counts as mit.
- A package counts once per family if any of its `License:` fields matches. `both` means it matched gpl and permissive.
- Percentages are of all files found, including the ones it could not parse.

## Where it is rough

- **`GPL` also matches LGPL and AGPL.** The 67 % is the GPL family, not the GPL alone. The LGPL allows linking from closed software, so that is a real difference.
- **Packaging counts as code.** Many `copyright` files have a `Files: debian/*` paragraph for the packaging scripts, often under the GPL, even when the program itself is permissive.
- `--strict` removes both effects (no LGPL or AGPL, no `debian/*` paragraphs). On the same laptop:

  ```
  packages with a license file: 2447
         gpl:  1329  54.3%
  permissive:  1196  48.9%
         mit:   741  30.3%
        both:   747  30.5%
    unparsed:   354  14.5%
  ```

  With the strict count it is more than half, not two out of three, and "both" is a bit under a third.
- **354 files (14.5 %) have no `License:` field** (older free-form copyright files). They count as nothing, so every percentage is a little low.
- **It counts mentions, not code.** One GPL file in a package of a thousand MIT files counts the same as a fully GPL package.
  "Contains GPL code" means "at least one part is under it".
- **Dual licensing is not understood.** "GPL or MIT" (your choice) counts as both, the same as "GPL and MIT".
- **Files, not packages.** 66 of the doc folders on my laptop are symlinks to another package's folder, so those files are read twice. A few doc folders have no copyright file at all.
- The name matching is a plain text search without word boundaries. On this laptop that changes the permissive count by 2 packages.
- One laptop is not a survey. It is one real machine, shown as an example.

## Sources for the quotes in the video

Original texts:

- Bill Gates, "An Open Letter to Hobbyists", 1976: [text and scan](https://digibarn.com/collections/newsletters/homebrew/V2_01/gatesletter.html)
- Richard Stallman on the printer, KTH lecture, 1986: [gnu.org](https://www.gnu.org/philosophy/stallman-kth.html)
- The GNU announcement ("Free Unix!"), 1983: [gnu.org](https://www.gnu.org/gnu/initial-announcement.html)
- Stallman, "The GNU Project" (copyleft envelope, the verdict on X): [gnu.org](https://www.gnu.org/gnu/thegnuproject.html)
- GPL version 1, 1989: [gnu.org](https://www.gnu.org/licenses/old-licenses/gpl-1.0.txt)
- Linux release notes [0.01](https://www.kernel.org/pub/linux/kernel/Historic/old-versions/RELNOTES-0.01) and [0.12](https://www.kernel.org/pub/linux/kernel/Historic/old-versions/RELNOTES-0.12) (the move to the GPL)
- Jim Gettys on the MIT license: [opensource.com, 2019](https://opensource.com/article/19/4/history-mit-license)
- Christine Peterson, "How I coined the term 'open source'": [opensource.com, 2018](https://opensource.com/article/18/2/coining-term-open-source-software)
- Stallman, "Why Open Source Misses the Point of Free Software": [gnu.org](https://www.gnu.org/philosophy/open-source-misses-the-point.html)
- Bruce Perens, "It's Time to Talk about Free Software Again", 1999: [lwn.net](https://static.lwn.net/1999/0218/a/bp.html)
- The Halloween document (Microsoft memo, 1998), annotated: [catb.org](http://www.catb.org/~esr/halloween/halloween1.html)
- Craig Mundie, "The Commercial Software Model", 2001: [Microsoft transcript](https://news.microsoft.com/speeches/speech-transcript-craig-mundie-the-new-york-university-stern-school-of-business/)
- Linus Torvalds on GPLv3, kernel mailing list, June 2007: [14 June](https://lkml.iu.edu/hypermail/linux/kernel/0706.1/2611.html), [18 June](https://lkml.iu.edu/hypermail/linux/kernel/0706.2/1023.html)
- Microsoft's Hyper-V drivers for Linux, 2009: [kernel mailing list](https://lkml.iu.edu/hypermail/linux/kernel/0907.2/01249.html)
- License usage on GitHub, 2015: [GitHub blog](https://github.blog/2015-03-09-open-source-license-usage-on-github-com/)
- Microsoft joins the Linux Foundation, 2016: [press release](https://www.linuxfoundation.org/press/press-release/microsoft-fortifies-commitment-to-open-source-becomes-linux-foundation-platinum-member)

Quotes known from press reports of the time (I did not find an original recording or transcript):

- Steve Ballmer, "the characteristics of communism", 2000: [The Register](https://www.theregister.com/2000/07/31/ms_ballmer_linux_is_communism/)
- Jim Allchin, "an intellectual-property destroyer", 2001: [Salon, quoting Bloomberg](https://www.salon.com/2001/02/15/unamerican/)
- Steve Ballmer, "Linux is a cancer", 2001: [The Register, reporting a Chicago Sun-Times interview](https://www.theregister.com/2001/06/02/ballmer_linux_is_a_cancer/)
- The "Microsoft loves Linux" slide, 2014: [The Register](https://www.theregister.com/2014/10/20/microsoft_cloud_event/)
- Steve Ballmer, "made a ton of money", 2016: [The Register](https://www.theregister.com/2016/03/11/ballmer_linux_non_apology/)
