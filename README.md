# iOXcode

An iPhone app that builds iPhone apps, on the iPhone, with no Mac and no JIT.

Everything is ahead-of-time: compile Swift, link, sign normally. The first test subject is
[TamaiOS](https://github.com/jakebway/tamaios).

Status: measuring. The **Spike** workflow (Actions tab, Run workflow) compiles TamaiOS's Swift on a
macOS runner and reports compiler memory and time, which SDK files get read, and whether the
open-source linker (`lld`) can link the result. See [docs/PLAN.md](docs/PLAN.md).
