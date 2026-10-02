using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Aidd;

internal static class Program
{
    private static readonly string InstallDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".aidd");
    // ~/.aidd/<repo> は各リポジトリの clone。ビルド成果物は <repo>/publish に置く。
    private static readonly string HarnessRepoDir = Path.Combine(InstallDir, "ai-harness-main");
    private static readonly string CreateDocsRepoDir = Path.Combine(InstallDir, "aidd-create-docs");
    private static readonly string AiddRepoDir = Path.Combine(InstallDir, "aidd-script");
    private static readonly string TemplateRepoDir = Path.Combine(InstallDir, "aidd-template");
    private static readonly string DocsRepoDir = Path.Combine(InstallDir, "aidd-docs");

    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            return Fail("使い方: aidd --version | " +
                         "aidd --update-aidd [--protocol https|ssh] [--ssh-name <name>] [--org <org>] [--branch <branch>] | " +
                         "aidd --init | aidd --update-project");
        }

        try
        {
            var command = args[0];

            switch (command)
            {
                case "--version":
                    RunVersion(args.Skip(1).ToArray());
                    return 0;
                case "--update-aidd":
                    RunUpdateAidd(ParseOptions(args.Skip(1).ToArray()));
                    return 0;
                case "--init":
                    RunInit(args.Skip(1).ToArray());
                    return 0;
                case "--update-project":
                    RunUpdateProject(args.Skip(1).ToArray());
                    return 0;
                default:
                    return Fail($"不明な引数です: {command}");
            }
        }
        catch (AiddException ex)
        {
            return Fail(ex.Message);
        }
        catch (Exception ex)
        {
            return Fail($"予期しないエラーが発生しました: {ex.Message}");
        }
    }

    private static int Fail(string message)
    {
        Console.Error.WriteLine($"[aidd] {message}");
        return 1;
    }

    private static void Log(string message) => Console.WriteLine($"[aidd] {message}");

    // ---- 共通オプション（--protocol / --org / --branch） ----

    private static Dictionary<string, string> ParseOptions(IReadOnlyList<string> args)
    {
        var result = new Dictionary<string, string>();
        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            if (!arg.StartsWith("--", StringComparison.Ordinal))
            {
                throw new AiddException($"不明な引数です: {arg}");
            }
            var name = arg[2..];
            if (i + 1 >= args.Count)
            {
                throw new AiddException($"--{name} には値が必要です。");
            }
            result[name] = args[++i];
        }
        return result;
    }

    private static void ValidateOptions(IReadOnlyDictionary<string, string> options, params string[] allowedKeys)
    {
        var allowed = new HashSet<string>(allowedKeys);
        foreach (var key in options.Keys)
        {
            if (!allowed.Contains(key))
            {
                throw new AiddException($"不明な引数です: --{key}");
            }
        }
    }

    private static string GetOption(IReadOnlyDictionary<string, string> options, string name, string defaultValue)
        => options.TryGetValue(name, out var value) ? value : defaultValue;

    // sshName は ssh のときだけ意味を持つ（~/.ssh/config の Host エイリアス名。git@<sshName>:... の
    // ホスト部分）。未指定は github.com。https で指定されたら黙って無視せずエラーにする。
    private static string BuildRepoUrl(string protocol, string? sshName, string org, string repoName)
    {
        if (protocol != "ssh" && sshName is not null)
        {
            throw new AiddException("--ssh-name は --protocol ssh のときだけ指定できます。");
        }
        return protocol switch
        {
            "https" => $"https://github.com/{org}/{repoName}.git",
            "ssh" => $"git@{sshName ?? "github.com"}:{org}/{repoName}.git",
            _ => throw new AiddException($"--protocol は https か ssh のいずれかです: {protocol}"),
        };
    }

    // ---- --version（バージョンを標準出力へ。setup の動作確認が使う） ----

    private static void RunVersion(IReadOnlyList<string> args)
    {
        if (args.Count > 0)
        {
            throw new AiddException($"--version は引数を取りません: {args[0]}");
        }

        // csproj の <Version>。SDK が付ける「+<コミット>」も含めて表示する
        var version = typeof(Program).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? throw new AiddException("バージョン情報を取得できません。");
        Console.WriteLine($"aidd {version}");
    }

    // ---- --update-aidd（~/.aidd のツール一式: ai-harness-main / aidd-create-docs / aidd-docs） ----

    private static void RunUpdateAidd(IReadOnlyDictionary<string, string> options)
    {
        ValidateOptions(options, "protocol", "ssh-name", "org", "branch");
        var protocol = GetOption(options, "protocol", "https");
        var sshName = options.GetValueOrDefault("ssh-name");
        var org = GetOption(options, "org", "amagrammers");
        var branch = GetOption(options, "branch", "main");

        Directory.CreateDirectory(InstallDir);
        RequireCommand("git");
        RequireCommand("dotnet");

        // 旧配置の削除は発行済み exe を消すため、daemon を先に止める（Windows のファイルロック対策）
        if (IsLegacyLayout(HarnessRepoDir)) StopAiHarnessMain();

        var harnessChanged = SyncRepo(BuildRepoUrl(protocol, sshName, org, "ai-harness-main"), branch, HarnessRepoDir, "ai-harness-main");
        var createDocsChanged = SyncRepo(BuildRepoUrl(protocol, sshName, org, "aidd-create-docs"), branch, CreateDocsRepoDir, "aidd-create-docs");
        // aidd-script は public のため、org / protocol / ssh-name に依らず固定の https URL から取得する
        var aiddChanged = SyncRepo("https://github.com/amagrammers/aidd-script.git", branch, AiddRepoDir, "aidd-script");
        SyncRepo(BuildRepoUrl(protocol, sshName, org, "aidd-template"), branch, TemplateRepoDir, "aidd-template");
        SyncRepo(BuildRepoUrl(protocol, sshName, org, "aidd-docs"), branch, DocsRepoDir, "aidd-docs");

        // 差分が無くても、発行物が無ければ（前回の失敗など）ビルドする
        var harnessNeedsPublish = harnessChanged || !File.Exists(ExePath(HarnessRepoDir, "ai-harness-main"));
        var createDocsNeedsPublish = createDocsChanged || !File.Exists(ExePath(CreateDocsRepoDir, "aidd-create-docs"));

        if (harnessNeedsPublish)
        {
            StopAiHarnessMain();
            PublishDotnetTool(
                HarnessRepoDir, "ai-harness-main",
                csprojRelative: "src/main/ai-harness-main.csproj",
                pluginDirPrefix: "ai-harness-",
                baselibFileName: "ai-harness-baselib.dll",
                selfExtract: true);
        }
        if (createDocsNeedsPublish)
        {
            PublishDotnetTool(
                CreateDocsRepoDir, "aidd-create-docs",
                csprojRelative: "src/main/aidd-create-docs.csproj",
                pluginDirPrefix: "aidd-section-",
                baselibFileName: "aidd-create-docs-baselib.dll",
                selfExtract: false);
        }
        if (harnessNeedsPublish) RestartAiHarnessMain();

        // aidd 自身は最後に更新する（実行中のこのプロセスは旧版のまま終了し、次回から新版になる）
        if (aiddChanged || !File.Exists(ExePath(AiddRepoDir, "aidd")))
        {
            PublishDotnetTool(
                AiddRepoDir, "aidd",
                csprojRelative: "src/main/aidd.csproj",
                pluginDirPrefix: null,
                baselibFileName: null,
                selfExtract: false);
        }

        Log("アップデート完了。");
    }

    private static void RequireCommand(string name)
    {
        if (!CommandExists(name))
        {
            throw new AiddException($"{name} が見つかりません。先に setup を実行してください。");
        }
    }

    private static string CurrentRid()
    {
        var arch = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        if (OperatingSystem.IsWindows()) return $"win-{arch}";
        if (OperatingSystem.IsMacOS()) return $"osx-{arch}";
        return $"linux-{arch}";
    }

    private static string PublishDir(string repoDir) => Path.Combine(repoDir, "publish");

    private static string ExePath(string repoDir, string exeName)
        => Path.Combine(PublishDir(repoDir), OperatingSystem.IsWindows() ? exeName + ".exe" : exeName);

    // repoDir（~/.aidd/<repo> の clone）からビルドし、成果物を repoDir/publish へ発行する。
    private static void PublishDotnetTool(
        string repoDir, string exeName,
        string csprojRelative, string? pluginDirPrefix, string? baselibFileName, bool selfExtract)
    {
        var installDir = PublishDir(repoDir);
        Log($"{exeName} を {installDir} へ再発行します…");

        // 実行中の exe は Windows では上書き・削除できないが、名前の変更はできる。aidd 自身を
        // 再発行する場合に備え、先に退避する（.old は次回の再発行で削除される）。
        var currentExe = ExePath(repoDir, exeName);
        if (File.Exists(currentExe))
        {
            File.Move(currentExe, currentExe + ".old", overwrite: true);
        }
        // 失敗した発行の残骸を「発行済み」と取り違えないよう、先に消す
        TryDelete(installDir);
        Directory.CreateDirectory(installDir);

        Log("本体を発行します（self-contained 単一ファイル）…");
        var csproj = Path.Combine(repoDir, csprojRelative.Replace('/', Path.DirectorySeparatorChar));
        var publishArgs = new List<string>
        {
            "publish", csproj,
            "-c", "Release",
            "-r", CurrentRid(),
            "--self-contained", "true",
            "-p:PublishSingleFile=true",
        };
        if (selfExtract)
        {
            publishArgs.Add("-p:IncludeNativeLibrariesForSelfExtract=true");
        }
        // -tl:off は dotnet の要約表示（ターミナルロガー）を切る。端末へ直に出すと、日本語環境で
        // 語順の崩れた要約になるため。
        publishArgs.AddRange(["-tl:off", "-o", installDir]);
        Run("dotnet", [.. publishArgs]);

        // プラグインを持つツール（ai-harness-main / aidd-create-docs）だけ lib/ を作る
        if (pluginDirPrefix is not null && baselibFileName is not null)
        {
            var libDir = Path.Combine(installDir, "lib");
            Directory.CreateDirectory(libDir);

            var pluginsRoot = Path.Combine(repoDir, "src", "plugins");
            if (Directory.Exists(pluginsRoot))
            {
                foreach (var dir in Directory.GetDirectories(pluginsRoot, pluginDirPrefix + "*"))
                {
                    var csprojFile = Directory.GetFiles(dir, "*.csproj").FirstOrDefault();
                    if (csprojFile is null) continue;
                    Log($"  同梱プラグインをビルドします: {Path.GetFileName(dir)}");
                    Run("dotnet", "build", csprojFile, "-c", "Release", "-tl:off", "-o", libDir);
                }
            }

            // baselib は host / 本体が共有ロードするため lib/ には置かない
            var baselibPath = Path.Combine(libDir, baselibFileName);
            if (File.Exists(baselibPath)) File.Delete(baselibPath);
        }

        var exePath = ExePath(repoDir, exeName);
        if (!File.Exists(exePath))
        {
            throw new AiddException($"{exeName} の発行に失敗しました（{exePath} が見つかりません）。");
        }
        Log($"{exeName} を発行しました: {exePath}");
    }

    private static void StopAiHarnessMain()
    {
        // PATH 解決ではなく、このコマンド自身が発行した実体だけを対象にする
        // （PATH が別の配置を指している可能性を排除するため）。
        var exe = ResolveHarnessExe();
        if (exe is null)
        {
            Log("ai-harness-main が見つからないため --stop を飛ばします。");
            return;
        }
        Log("ai-harness-main --stop で常駐 daemon を停止します（再発行時のファイルロックを避けるため）…");
        _ = TryExecute(exe, ["--stop"], out _);
    }

    private static void RestartAiHarnessMain()
    {
        var exe = ResolveHarnessExe();
        if (exe is null)
        {
            Log("ai-harness-main が見つからないため --restart を飛ばします。");
            return;
        }
        Log("ai-harness-main --restart で DLL の差し替えを反映します…");
        Run(exe, "--restart");
    }

    private static string? ResolveHarnessExe()
    {
        var exeName = OperatingSystem.IsWindows() ? "ai-harness-main.exe" : "ai-harness-main";
        // 旧配置（clone なしで ~/.aidd/ai-harness-main 直下に発行していた）も停止対象に含める
        string[] candidates = [Path.Combine(PublishDir(HarnessRepoDir), exeName), Path.Combine(HarnessRepoDir, exeName)];
        return candidates.FirstOrDefault(File.Exists);
    }

    // ---- --init（~/.aidd の aidd-template と aidd-docs/core をカレントディレクトリへコピー。取得はしない） ----

    private static void RunInit(IReadOnlyList<string> args)
    {
        if (args.Count > 0)
        {
            throw new AiddException($"--init は引数を取りません: {args[0]}");
        }

        if (!Directory.Exists(TemplateRepoDir))
        {
            throw new AiddException($"{TemplateRepoDir} がありません。先に aidd --update-aidd を実行してください。");
        }
        var docsCoreDir = Path.Combine(DocsRepoDir, "core");
        if (!Directory.Exists(docsCoreDir))
        {
            throw new AiddException($"{docsCoreDir} がありません。先に aidd --update-aidd を実行してください。");
        }

        var dest = Directory.GetCurrentDirectory();

        // .docs/ は aidd-docs が正本なので、aidd-template 側に .docs/ があってもそちらは使わない
        var templateFiles = Directory.EnumerateFiles(TemplateRepoDir, "*", SearchOption.AllDirectories)
            .Where(f => !IsUnderTopLevelDir(TemplateRepoDir, f, ".git"))
            .Where(f => !IsUnderTopLevelDir(TemplateRepoDir, f, ".docs"))
            .Where(f => !IsTopLevelFile(TemplateRepoDir, f, "README.md"))
            .Select(f => (Source: f, Target: Path.Combine(dest, Path.GetRelativePath(TemplateRepoDir, f))))
            .ToList();

        var docsFiles = Directory.EnumerateFiles(docsCoreDir, "*", SearchOption.AllDirectories)
            .Select(f => (Source: f, Target: Path.Combine(dest, ".docs", Path.GetRelativePath(docsCoreDir, f))))
            .ToList();

        var all = templateFiles.Concat(docsFiles).ToList();

        // 一部だけ書いて失敗する状態を避けるため、書き込み前に全件の衝突を検査する
        // 既存のファイル・ディレクトリは上書きしない。template と docs の出力先が重なる場合も上書きになるため衝突とみなす
        var conflicts = all.Select(x => x.Target)
            .Where(t => File.Exists(t) || Directory.Exists(t))
            .Concat(all.GroupBy(x => x.Target).Where(g => g.Count() > 1).Select(g => g.Key))
            .Distinct()
            .ToList();
        if (conflicts.Count > 0)
        {
            var list = string.Join("\n", conflicts.Select(c => "            " + c));
            throw new AiddException($"以下のパスが既に存在する、または出力先が重複するため中断しました。何も変更していません:\n{list}");
        }

        foreach (var (src, target) in all)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(src, target, overwrite: false);
        }

        Log($"aidd-template から {templateFiles.Count} ファイル、aidd-docs/core から {docsFiles.Count} " +
            $"ファイルを {dest} へコピーしました。");
    }

    private static bool IsTopLevelFile(string root, string filePath, string fileName)
        => Path.GetRelativePath(root, filePath) == fileName;

    private static bool IsUnderTopLevelDir(string root, string filePath, string topLevelName)
    {
        var rel = Path.GetRelativePath(root, filePath);
        return rel.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)[0] == topLevelName;
    }

    // ---- --update-project（~/.aidd/aidd-docs/core でカレントディレクトリの .docs/ を置換。取得はしない） ----
    // 正本は aidd-docs の core/。clone の作業ツリーをそのまま読む。

    private static void RunUpdateProject(IReadOnlyList<string> args)
    {
        if (args.Count > 0)
        {
            throw new AiddException($"--update-project は引数を取りません: {args[0]}");
        }

        var docsCoreDir = Path.Combine(DocsRepoDir, "core");
        if (!Directory.Exists(docsCoreDir))
        {
            throw new AiddException($"{docsCoreDir} がありません。先に aidd --update-aidd を実行してください。");
        }

        var target = Path.Combine(Directory.GetCurrentDirectory(), ".docs");
        // 途中で失敗しても既存の .docs/ を失わないよう、隣へ全件コピーしてから差し替える。
        var staging = target + ".new";
        TryDelete(staging);
        try
        {
            var count = 0;
            foreach (var src in Directory.EnumerateFiles(docsCoreDir, "*", SearchOption.AllDirectories))
            {
                var dest = Path.Combine(staging, Path.GetRelativePath(docsCoreDir, src));
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.Copy(src, dest);
                count++;
            }

            if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
            Directory.Move(staging, target);
            Log($"aidd-docs/core の {count} ファイルで {target} を置換しました。");
        }
        catch
        {
            TryDelete(staging);
            throw;
        }
    }

    // ---- リポジトリの取得（~/.aidd/<repo> に clone を置き、差分があるときだけ揃える） ----

    // .git を持たない配置（clone を置かず成果物だけを置いていた旧配置）
    private static bool IsLegacyLayout(string repoDir)
        => Directory.Exists(repoDir) && !Directory.Exists(Path.Combine(repoDir, ".git"));

    // 戻り値は「clone した、または差分を取り込んだ」か。差分が無ければ false（何も変更しない）。
    private static bool SyncRepo(string repoUrl, string branch, string repoDir, string label)
    {
        if (IsLegacyLayout(repoDir))
        {
            Log($"{label}: 旧配置（clone なし）を削除して clone し直します。");
            Directory.Delete(repoDir, recursive: true);
        }

        if (!Directory.Exists(repoDir))
        {
            Log($"{label} を {repoDir} へ clone します（branch: {branch}）…");
            Run("git", "clone", "--quiet", "--depth", "1", "--branch", branch, repoUrl, repoDir);
            return true;
        }

        // org / protocol の変更に追随するため、毎回 remote を指定どおりに揃える
        Run("git", "-C", repoDir, "remote", "set-url", "origin", repoUrl);
        Run("git", "-C", repoDir, "fetch", "--quiet", "--depth", "1", "origin", branch);
        var head = RunCapture("git", "-C", repoDir, "rev-parse", "HEAD");
        var remote = RunCapture("git", "-C", repoDir, "rev-parse", "FETCH_HEAD");
        if (head == remote)
        {
            Log($"{label}: 差分なし（{head[..7]}）。");
            return false;
        }

        Run("git", "-C", repoDir, "reset", "--quiet", "--hard", "FETCH_HEAD");
        Log($"{label}: {head[..7]} → {remote[..7]} へ更新しました。");
        return true;
    }

    // ---- process helpers ----

    private static string RunCapture(string fileName, params string[] arguments)
    {
        var psi = new ProcessStartInfo(fileName) { UseShellExecute = false, RedirectStandardOutput = true };
        foreach (var arg in arguments) psi.ArgumentList.Add(arg);

        using var process = Process.Start(psi)
            ?? throw new AiddException($"コマンドを起動できません: {fileName}");
        var output = process.StandardOutput.ReadToEnd().Trim();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new AiddException($"コマンドが失敗しました: {fileName} {string.Join(' ', arguments)}");
        }
        return output;
    }

    private static void Run(string fileName, params string[] arguments)
    {
        if (!TryExecute(fileName, arguments, out var exitCode) || exitCode != 0)
        {
            throw new AiddException($"コマンドが失敗しました: {fileName} {string.Join(' ', arguments)}");
        }
    }

    private static bool CommandExists(string fileName)
    {
        return TryExecute(fileName, ["--version"], out var exitCode) && exitCode == 0;
    }

    private static bool TryExecute(string fileName, IReadOnlyList<string> arguments, out int exitCode)
    {
        var psi = new ProcessStartInfo(fileName) { UseShellExecute = false };
        foreach (var arg in arguments) psi.ArgumentList.Add(arg);

        try
        {
            using var process = Process.Start(psi);
            if (process is null)
            {
                exitCode = -1;
                return false;
            }
            process.WaitForExit();
            exitCode = process.ExitCode;
            return true;
        }
        catch (Exception)
        {
            exitCode = -1;
            return false;
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        }
        catch
        {
            // ベストエフォート
        }
    }
}

internal sealed class AiddException(string message) : Exception(message);
