#import "DocumentCommand.h"
#import "DocumentController.h"
#import <OakAppKit/OakToolTip.h>
#import <OakAppKit/OakAppKit.h>
#import <OakFoundation/NSString Additions.h>
#import <BundleEditor/BundleEditor.h>
#import <HTMLOutputWindow/HTMLOutputWindow.h>
#import <OakTextView/OakDocumentView.h>
#import <OakFileBrowser/OakFileBrowser.h>
#import <OakSystem/application.h>
#import <OakSystem/process.h>
#import <command/runner.h>
#import <ns/ns.h>
#import <oak/oak.h>
#import <bundles/bundles.h>
#import <document/collection.h>
#import <document/OakDocument.h>
#import <editor/editor.h>
#import <editor/write.h>
#import <io/path.h>
#import <text/trim.h>
#import <text/tokenize.h>

namespace
{
	struct delegate_t : command::delegate_t
	{
		delegate_t (DocumentController* controller, ng::buffer_api_t const& buffer, ng::ranges_t const& selection, document::document_ptr document) : _controller(controller), _buffer(buffer), _selection(selection), _document(document), _did_open_html_window(false)
		{
			if(_controller)
				_collection = to_s(_controller.identifier);
		}

		ng::ranges_t write_unit_to_fd (int fd, input::type unit, input::type fallbackUnit, input_format::type format, scope::selector_t const& scopeSelector, std::map<std::string, std::string>& variables, bool* inputWasSelection);

		bool accept_html_data (command::runner_ptr runner, char const* data, size_t len);
		bool accept_result (std::string const& out, output::type placement, output_format::type format, output_caret::type outputCaret, ng::ranges_t const& inputRanges, std::map<std::string, std::string> const& environment);
		void discard_html ();

		void show_tool_tip (std::string const& str);
		void show_document (std::string const& str);
		void show_error (bundle_command_t const& command, int rc, std::string const& out, std::string const& err);

	private:
		DocumentController* _controller;
		ng::buffer_api_t const& _buffer;
		ng::ranges_t _selection;
		document::document_ptr _document;
		oak::uuid_t _collection;
		bool _did_open_html_window;
	};
}

// =======================
// = Init, Saving, Input =
// =======================

ng::ranges_t delegate_t::write_unit_to_fd (int fd, input::type unit, input::type fallbackUnit, input_format::type format, scope::selector_t const& scopeSelector, std::map<std::string, std::string>& variables, bool* inputWasSelection)
{
	if(!_document)
	{
		close(fd);
		return { };
	}

	bool isOpen = _document->is_open();
	if(!isOpen)
		_document->sync_open();
	ng::ranges_t const res = ng::write_unit_to_fd(_buffer, _selection, _document->indent().tab_size(), fd, unit, fallbackUnit, format, scopeSelector, variables, inputWasSelection);
	if(!isOpen)
		_document->close();
	return res;
}

// ====================
// = Accepting Output =
// ====================

bool delegate_t::accept_html_data (command::runner_ptr runner, char const* data, size_t len)
{
	if(!_did_open_html_window)
	{
		_did_open_html_window = true;
		if(_controller)
				[_controller setCommandRunner:runner];
		else	[HTMLOutputWindowController HTMLOutputWindowWithRunner:runner];
	}
	return true;
}

void delegate_t::discard_html ()
{
	if(_did_open_html_window && _controller.htmlOutputVisible)
		_controller.htmlOutputVisible = NO;
}

bool delegate_t::accept_result (std::string const& out, output::type placement, output_format::type format, output_caret::type outputCaret, ng::ranges_t const& inputRanges, std::map<std::string, std::string> const& environment)
{
	bool res;
	if(_document && _document->is_open())
	{
		res = [_document->document() handleOutput:out placement:placement format:format caret:outputCaret inputRanges:inputRanges environment:environment];
	}
	else
	{
		document::document_ptr doc = document::create();
		doc->sync_open();
		res = [doc->document() handleOutput:out placement:placement format:format caret:outputCaret inputRanges:ng::range_t(0) environment:environment];
		document::show(doc);
		doc->close();
	}
	return res;
}

// ========================================
// = Showing tool tip, document, or error =
// ========================================

void delegate_t::show_tool_tip (std::string const& str)
{
	NSPoint location = _controller ? [_controller positionForWindowUnderCaret] : [NSEvent mouseLocation];
	OakShowToolTip([NSString stringWithCxxString:str], location);
}

void delegate_t::show_document (std::string const& str)
{
	document::show(document::from_content(str), _collection);
}

void delegate_t::show_error (bundle_command_t const& command, int rc, std::string const& out, std::string const& err)
{
	show_command_error(text::trim(err + out).empty() ? text::format("Command returned status code %d.", rc) : err + out, command.uuid, _controller.window, command.name);
}

// ==============
// = Public API =
// ==============

void run_impl (bundle_command_t const& command, ng::buffer_api_t const& buffer, ng::ranges_t const& selection, document::document_ptr document, std::map<std::string, std::string> baseEnv, std::string const& pwd)
{
	DocumentController* controller = [DocumentController controllerForDocument:document];
	if(controller && command.output == output::new_window && command.output_format == output_format::html)
	{
		if(command.output_reuse == output_reuse::reuse_busy || command.output_reuse == output_reuse::abort_and_reuse_busy)
		{
			bundle_command_t cmd = command;
			cmd.output_reuse = output_reuse::reuse_available; // Avoid infinite loop when completionHandler calls us
			ng::ranges_t sel = selection;
			std::string dir  = pwd;

			[controller bundleItemReuseOutputForCommand:command completionHandler:^(BOOL success){
				if(success)
					run_impl(cmd, buffer, sel, document, baseEnv, dir);
			}];
			return;
		}
	}

	if(controller && command.pre_exec != pre_exec::nop)
	{
		bundle_command_t cmd = command;
		cmd.pre_exec = pre_exec::nop;

		ng::ranges_t sel = selection;
		std::string dir  = pwd;

		[controller bundleItemPreExec:command.pre_exec completionHandler:^(BOOL success){
			run_impl(cmd, buffer, sel, document, baseEnv, dir);
		}];

		return;
	}

	if(bundles::item_ptr item = bundles::lookup(command.uuid))
	{
		bundles::required_command_t failedRequirement;
		if(missing_requirement(item, baseEnv, &failedRequirement))
		{
			std::vector<std::string> paths;
			std::string const tmp = baseEnv["PATH"];
			for(auto path : text::tokenize(tmp.begin(), tmp.end(), ':'))
			{
				if(path != "" && path::is_directory(path))
					paths.push_back(path::with_tilde(path));
			}

			std::string const title = text::format("Unable to run “%.*s”.", (int)command.name.size(), command.name.data());
			std::string message;
			if(failedRequirement.variable != NULL_STR)
					message = text::format("This command requires ‘%1$s’ which wasn’t found on your system.\n\nThe following locations were searched:%2$s\n\nIf ‘%1$s’ is installed elsewhere then you need to set %3$s in Preferences → Variables to the full path of where you installed it.", failedRequirement.command.c_str(), ("\n\u2003• " + text::join(paths, "\n\u2003• ")).c_str(), failedRequirement.variable.c_str());
			else	message = text::format("This command requires ‘%1$s’ which wasn’t found on your system.\n\nThe following locations were searched:%2$s\n\nIf ‘%1$s’ is installed elsewhere then you need to set PATH in Preferences → Variables to include the folder in which it can be found.", failedRequirement.command.c_str(), ("\n\u2003• " + text::join(paths, "\n\u2003• ")).c_str());

			NSAlert* alert = [[NSAlert alloc] init];
			[alert setAlertStyle:NSCriticalAlertStyle];
			[alert setMessageText:[NSString stringWithCxxString:title]];
			[alert setInformativeText:[NSString stringWithCxxString:message]];
			[alert addButtonWithTitle:@"OK"];
			if(failedRequirement.more_info_url != NULL_STR)
				[alert addButtonWithTitle:@"More Info…"];

			NSString* moreInfo = [NSString stringWithCxxString:failedRequirement.more_info_url];
			OakShowAlertForWindow(alert, [controller window], ^(NSInteger button){
				if(button == NSAlertSecondButtonReturn)
					[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:moreInfo]];
			});
			return;
		}
	}

	command::runner_ptr runner = command::runner(command, buffer, selection, baseEnv, std::make_shared<delegate_t>(controller, buffer, selection, document), pwd);
	runner->launch();
	runner->wait();
}

void show_command_error (std::string const& message, oak::uuid_t const& uuid, NSWindow* window, std::string commandName)
{
	bundles::item_ptr bundleItem = bundles::lookup(uuid);
	if(commandName == NULL_STR)
		commandName = bundleItem ? bundleItem->name() : "(unknown)";

	NSAlert* alert = [[NSAlert alloc] init];
	[alert setAlertStyle:NSCriticalAlertStyle];
	[alert setMessageText:[NSString stringWithCxxString:text::format("Failure running “%.*s”.", (int)commandName.size(), commandName.data())]];
	[alert setInformativeText:[NSString stringWithCxxString:message] ?: @"No output"];
	[alert addButtonWithTitle:@"OK"];
	if(bundleItem)
		[alert addButtonWithTitle:@"Edit Command"];

	OakShowAlertForWindow(alert, window, ^(NSInteger button){
		if(button == NSAlertSecondButtonReturn)
			[[BundleEditor sharedInstance] revealBundleItem:bundleItem];
	});
}
