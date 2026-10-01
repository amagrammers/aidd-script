using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Aidd;

internal static class Program
{
    private static readonly string InstallDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".aidd");
    private static readonly string HarnessInstallDir = Path.Combine(InstallDir, "ai-harness-main");
    private static readonly string CreateDocsInstallDir = Path.Combine(InstallDir, "aidd-create-docs");
    private static readonly string DocsInstallDir = Path.Combine(InstallDir, "aidd-docs");

    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            return Fail("使い方: aidd --update-aidd [--protocol https|ssh] [--org <org>] [--branch <branch>] | " +
                         "aidd --update-project");
        }

        try
        {
            var command = args[0];

            switch (command)
            {
                case "--update-aidd":
                    RunUpdateAidd(ParseOptions(args.Skip(1).ToArray()));
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

    private static string BuildRepoUrl(string protocol, string org, string repoName) => protocol switch
    {
        "https" => $"https://github.com/{org}/{repoName}.git",
        "ssh" => $"git@github.com:{org}/{repoName}.git",
        _ => throw new AiddException($"--protocol は https か ssh のいずれかです: {protocol}"),
    };

    // ---- --update-aidd（~/.aidd のツール一式: ai-harness-main / aidd-create-docs / aidd-docs） ----

    private static void RunUpdateAidd(IReadOnlyDictionary<string, string> options)
    {
        ValidateOptions(options, "protocol", "org", "branch");
        var protocol = GetOption(options, "protocol", "https");
        var org = GetOption(options, "org", "amagrammers");
        var branch = GetOption(options, "branch", "main");

        Directory.CreateDirectory(InstallDir);
        RequireCommand("git");
        RequireCommand("dotnet");

        StopAiHarnessMain();
        PublishDotnetTool(
            BuildRepoUrl(protocol, org, "ai-harness-main"), branch, HarnessInstallDir, "ai-harness-main",
            csprojRelative: "src/main/ai-harness-main.csproj",
            pluginDirPrefix: "ai-harness-",
            baselibFileName: "ai-harness-baselib.dll",
            selfExtract: true);
        PublishDotnetTool(
            BuildRepoUrl(protocol, org, "aidd-create-docs"), branch, CreateDocsInstallDir, "aidd-create-docs",
            csprojRelative: "src/main/aidd-create-docs.csproj",
            pluginDirPrefix: "aidd-section-",
            baselibFileName: "aidd-create-docs-baselib.dll",
            selfExtract: false);
        RefreshPlainCheckout(BuildRepoUrl(protocol, org, "aidd-docs"), branch, DocsInstallDir, "aidd-docs");
        RestartAiHarnessMain();

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

    private static void PublishDotnetTool(
        string repoUrl, string branch, string installDir, string exeName,
        string csprojRelative, string pluginDirPrefix, string baselibFileName, bool selfExtract)
    {
        Log($"{exeName} を {installDir} へ再発行します（branch: {branch}）…");
        Directory.CreateDirectory(installDir);

        var work = Directory.CreateTempSubdirectory($"{exeName}-src-");
        try
        {
            Log($"{exeName} を clone します…");
            Run("git", "clone", "--quiet", "--depth", "1", "--branch", branch, repoUrl, work.FullName);

            Log("本体を発行します（self-contained 単一ファイル）…");
            var csproj = Path.Combine(work.FullName, csprojRelative.Replace('/', Path.DirectorySeparatorChar));
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

            var libDir = Path.Combine(installDir, "lib");
            Directory.CreateDirectory(libDir);

            var pluginsRoot = Path.Combine(work.FullName, "src", "plugins");
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
        finally
        {
            TryDelete(work.FullName);
        }

        var exePath = Path.Combine(installDir, OperatingSystem.IsWindows() ? exeName + ".exe" : exeName);
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
        var exePath = Path.Combine(HarnessInstallDir, OperatingSystem.IsWindows() ? "ai-harness-main.exe" : "ai-harness-main");
        return File.Exists(exePath) ? exePath : null;
    }

    // ---- --update-project（~/.aidd/aidd-docs/core でカレントディレクトリの .docs/ を置換。取得はしない） ----

    private static void RunUpdateProject(IReadOnlyList<string> args)
    {
        if (args.Count > 0)
        {
            throw new AiddException($"--update-project は引数を取りません: {args[0]}");
        }

        var docsCoreDir = Path.Combine(DocsInstallDir, "core");
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

    // git clone のみで dotnet ビルドを伴わない取得。
    // 毎回 clone し直して丸ごと置き換える（差分 pull はしない）。
    private static void RefreshPlainCheckout(string repoUrl, string branch, string installDir, string label)
    {
        Log($"{label} を {installDir} へ取得します（branch: {branch}）…");
        var work = Directory.CreateTempSubdirectory($"{label}-src-");
        try
        {
            Run("git", "clone", "--quiet", "--depth", "1", "--branch", branch, repoUrl, work.FullName);

            var gitDir = Path.Combine(work.FullName, ".git");
            if (Directory.Exists(gitDir)) Directory.Delete(gitDir, recursive: true);

            if (Directory.Exists(installDir)) Directory.Delete(installDir, recursive: true);
            Directory.Move(work.FullName, installDir);
        }
        catch
        {
            TryDelete(work.FullName);
            throw;
        }
        Log($"{label} を取得しました: {installDir}");
    }

    // ---- process helpers ----

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
