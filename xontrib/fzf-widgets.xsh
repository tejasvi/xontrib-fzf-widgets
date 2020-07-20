import os
import re
import subprocess
from xonsh.history.main import history_main
from xonsh.completers.path import complete_path
from prompt_toolkit.keys import Keys
from pathlib import Path
from xonsh import built_ins
import xontrib

__all__ = ()

def get_fzf_binary_name():
    fzf_tmux_cmd = 'fzf-tmux'
    if 'TMUX' in ${...} and $(which fzf_tmux_cmd):
        return fzf_tmux_cmd
    return 'fzf'


def get_fzf_binary_path():
    path = $(which @(get_fzf_binary_name()))
    if not path:
        raise Exception("Could not determine path of fzf using `which`; maybe it is not installed or not on PATH?")
    return path


def get_cursor_prefix(event):
    before_cursor = event.current_buffer.document.current_line_before_cursor
    delim_pos = before_cursor.rfind(' ', 0, len(before_cursor))
    if delim_pos == -1 and len(before_cursor):
        return before_cursor[:len(before_cursor)]
    if delim_pos != len(before_cursor) - 1:
        return before_cursor[delim_pos+1:]


def fzf_insert_history(event):
    # Run fzf, feeding it the xonsh history
    # fzf prints the user's choice on stdout.

    # universal_newlines=True is used because `history_main` writes str()s
    # That also means that we don't have to `decode()` the stdout.read()` below.
    popen_args = [get_fzf_binary_path(), '--read0', '--tac', '--no-sort', '--tiebreak=index', '+m', '--reverse', '--height=40%']
    if len(event.current_buffer.text) > 0:
        popen_args.append(f'-q ^{event.current_buffer.text}')
    proc = subprocess.Popen(popen_args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, universal_newlines=True)
    history_main(args=['show', '-0', 'all'], stdout=proc.stdin)
    proc.stdin.close()
    proc.wait()
    choice = proc.stdout.read().strip()

    # Redraw the shell because fzf used alternate mode
    event.cli.renderer.erase()

    if choice:
        event.current_buffer.text = choice


def fzf_insert_file(event, dirs_only=False):
    before_cursor = event.current_buffer.document.current_line_before_cursor
    delim_pos = before_cursor.rfind(' ', 0, len(before_cursor))
    prefix = None
    if delim_pos != -1 and delim_pos != len(before_cursor) - 1:
        prefix = before_cursor[delim_pos+1:]

    cwd = None
    path = ''
    if prefix:
        paths = complete_path(os.path.normpath(prefix), before_cursor, 0, len(before_cursor), None)[0]
        if len(paths) == 1:
            path = paths.pop()
            expanded_path = os.path.expanduser(path)
            if os.path.isdir(expanded_path):
                cwd = os.getcwd()
                os.chdir(expanded_path)

    env = os.environ
    if dirs_only:
        if 'fzf_find_dirs_command' in ${...}:
            env['FZF_DEFAULT_COMMAND'] = $fzf_find_dirs_command
    else:
        if 'fzf_find_command' in ${...}:
            env['FZF_DEFAULT_COMMAND'] = $fzf_find_command
    if 'FZF_DEFAULT_OPTS' in ${...}:
        env['FZF_DEFAULT_OPTS'] = $FZF_DEFAULT_OPTS
    choice = subprocess.run([get_fzf_binary_path(), '-m', '--reverse', '--height=40%'], stdout=subprocess.PIPE, universal_newlines=True, env=env).stdout.strip()

    if cwd:
        os.chdir(cwd)

    event.cli.renderer.erase()

    if choice:
        if path:
            event.current_buffer.delete_before_cursor(len(prefix))

        command = ''
        for c in choice.splitlines():
            command += "'" + os.path.join(path, c.strip()) + "' "

        event.current_buffer.insert_text(command.strip())


def fzf_prompt_from_string(string):
    choice = subprocess.run([get_fzf_binary_path(), '--tiebreak=index', '+m', '--reverse', '--height=40%'], input=string, stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
    return choice


@events.on_ptk_create
def custom_keybindings(bindings, **kw):
    def handler(key_name):
        def do_nothing(func):
            pass

        key = ${...}.get(key_name)
        if key:
            return bindings.add(key)
        return do_nothing

    @handler('fzf_history_binding')
    def fzf_history(event):
        fzf_insert_history(event)

    @handler('fzf_ssh_binding')
    def fzf_ssh(event):
        items = '\n'.join(
             re.findall(r'Host\s(.*)\n?',
                        $(cat ~/.ssh/config /etc/ssh/ssh_config),
                        re.IGNORECASE)
        )
        choice = fzf_prompt_from_string(items)

        # Redraw the shell because fzf used alternate mode
        event.cli.renderer.erase()

        if choice:
            event.current_buffer.insert_text('ssh ' + choice)

    @handler('fzf_file_binding')
    def fzf_file(event):
        fzf_insert_file(event)

    @handler('fzf_dir_binding')
    def fzf_dir(event):
        fzf_insert_file(event, True)

    @handler('fzf_z_binding')
    def fzf_z(event):

        bookmarks = Path(
            __xonsh__.env.get(
                "SHELL_BOOKMARKS",
                os.path.expanduser("~/.shell_bookmarks")
            )
        )

        if bookmarks.is_file():
            with open(bookmarks, "r") as f:
                bookmark_items = [_.rstrip() for _ in f if _]
        else:
            bookmark_items = []

        try:
            z_items = xontrib.z.ZHandler.handler(["-l", ""]).splitlines()
        except AttributeError:
            z_items = []

        items = "\n".join(bookmark_items + z_items)

        args = [get_fzf_binary_path(),'--tiebreak=index', '+m', '--reverse', '--height=40%']
        prefix = get_cursor_prefix(event)
        if prefix:
            args.append(f'-q {prefix}')

        choice = subprocess.run(
            args,
            input=items,
            stdout=subprocess.PIPE,
            universal_newlines=True).stdout.strip()

        # Redraw the shell because fzf used alternate mode
        event.cli.renderer.erase()

        if not choice:
            return

        if prefix:
            event.current_buffer.delete_before_cursor(len(prefix))

        if (
            event.current_buffer.document.cursor_position == 0 and
            os.path.isdir(choice)
        ):
            xonsh.built_ins.cd([choice])
            return

        event.current_buffer.insert_text(f"'{choice}'")
