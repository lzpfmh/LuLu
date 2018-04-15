//
//  file: RulesWindowController.m
//  project: lulu (main app)
//  description: window controller for 'rules' table
//
//  created by Patrick Wardle
//  copyright (c) 2017 Objective-See. All rights reserved.
//

#import "consts.h"
#import "Rule.h"
#import "RuleRow.h"
#import "logging.h"
#import "utilities.h"
#import "AppDelegate.h"
#import "DaemonComms.h"
#import "RulesWindowController.h"
#import "AddRuleWindowController.h"

@implementation RulesWindowController

@synthesize rules;
@synthesize toolbar;
@synthesize searchBox;
@synthesize daemonComms;
@synthesize addRulePanel;
@synthesize shouldFilter;
@synthesize rulesFiltered;
@synthesize rulesStatusMsg;

//alloc/init
// ->get rules and listen for new ones
-(void)windowDidLoad
{
    //alloc rules array
    rules = [NSMutableArray array];
    
    //alloc filtered rules array
    rulesFiltered = [NSMutableArray array];
    
    //init daemon comms obj
    daemonComms = [[DaemonComms alloc] init];
    
    //start by no filtering
    self.shouldFilter = NO;
    
    //unset message
    self.rulesStatusMsg.stringValue = @"";
    
    //get rules from daemon via XPC
    [self.daemonComms getRules:NO reply:^(NSDictionary* daemonRules)
    {
         //dbg msg
         logMsg(LOG_DEBUG, [NSString stringWithFormat:@"got rules from daemon: %@", daemonRules]);
         
         //process daemon rules
         [self processRulesDictionary:daemonRules];
         
         //dbg msg
         logMsg(LOG_DEBUG, [NSString stringWithFormat:@"processed rules: %@", self.rules]);
         
         //set 'all' as default selected
         self.toolbar.selectedItemIdentifier = @"all";
        
         //reload table
         [self.tableView reloadData];
        
         //select first row
         [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        
     }];
    
    //in background
    // monitor & process new rules
    [self performSelectorInBackground:@selector(listenForRuleChanges) withObject:nil];
}

//toolbar button handle
// generate filtered rules and reload table
-(IBAction)toolbarHandler:(id)sender
{
    //toolbar item tag
    NSInteger tag = -1;
    
    //grab tag
    tag = ((NSToolbarItem*)sender).tag;
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"user clicked %@ (tag: %ld)", ((NSToolbarItem*)sender).label, (long)tag]);
    
    //filter rules
    // based on selected toolbar item
    [self filterRules];
    
    //set column title
    switch (tag)
    {
        //all
        case RULE_TYPE_ALL:
            
            //set title
            self.tableView.tableColumns.firstObject.headerCell.stringValue = @"process";
            
            break;
            
        //default
        case RULE_TYPE_DEFAULT:
            
            //set title
            self.tableView.tableColumns.firstObject.headerCell.stringValue = @"process (os binaries, required for system functionality)";
            
            break;
            
        //apple
        case RULE_TYPE_APPLE:
            
            //set title
            self.tableView.tableColumns.firstObject.headerCell.stringValue = @"process (apple binaries, automatically approved)";
            
            break;
            
        //baseline
        case RULE_TYPE_BASELINE:
            
            //set title
            self.tableView.tableColumns.firstObject.headerCell.stringValue = @"process (pre-installed 3rd-party applications, automatically approved)";
            
            break;
            
        //all
        case RULE_TYPE_USER:
            
            //set title
            self.tableView.tableColumns.firstObject.headerCell.stringValue = @"process (binaries/applications added by the user)";
            
            break;
        
        default:
            break;
    }
    
    //reload table
    [self.tableView reloadData];
    
    //'add rules' only allowed for 'all' and 'user' views
    if( (tag == RULE_TYPE_ALL) ||
        (tag == RULE_TYPE_USER) )
    {
        //change label color to black
        self.addRuleLabel.textColor = [NSColor blackColor];
        
        //enable button
        self.addRuleButton.enabled = YES;
    }
    //'add rule' not allowed for 'default'/'apple'/'baseline'
    else
    {
        //change label color to gray
        self.addRuleLabel.textColor = [NSColor lightGrayColor];
        
        //disable button
        self.addRuleButton.enabled = NO;
    }
    
    //select first row
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    
    return;
}

//import rules
-(IBAction)importRules:(id)sender
{
    //'open' panel
    NSOpenPanel *panel = nil;
    
    //set status message
    self.rulesStatusMsg.stringValue = @"importing rules...";
    
    //init panel
    panel = [NSOpenPanel openPanel];
    
    //allow files
    panel.canChooseFiles = YES;
    
    //no directories
    panel.canChooseDirectories = NO;

    //disable multiple selections
    panel.allowsMultipleSelection = NO;
    
    //show panel
    [panel beginWithCompletionHandler:^(NSInteger result)
    {
        //only need to handle 'ok'
        if(NSFileHandlingPanelOKButton == result)
        {
            //dbg msg
            logMsg(LOG_DEBUG, [NSString stringWithFormat:@"importing rules from %@", panel.URL.path]);
            
            //send msg to daemon to XPC
            if(YES != [self.daemonComms importRules:panel.URL.path])
            {
                //err msg
                logMsg(LOG_ERR, @"failed to import rules");
                
                //update msg
                self.rulesStatusMsg.stringValue = @"failed to import rules";
            }
            //happy
            else
            {
                //update msg
                self.rulesStatusMsg.stringValue = @"imported rules";
            }
            
        }//clicked 'ok' (to save)
        
        //remove msg shortly thereafter
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            
            //update msg
            self.rulesStatusMsg.stringValue = @"";
            
        });
        
    }]; //panel completion handler
  
    return;
}

//serialize all rules
// and save them to disk
-(IBAction)exportRules:(id)sender
{
    //save panel
    NSSavePanel *panel = nil;
    
    //serialized rules
    __block NSMutableDictionary* serializedRules = nil;
    
    //alert
    __block NSAlert* alert = nil;
    
    //set status message
    self.rulesStatusMsg.stringValue = @"exporting rules...";

    //create panel
    panel = [NSSavePanel savePanel];
    
    //suggest file name
    [panel setNameFieldStringValue:RULES_FILE];
    
    //show panel
    // ->completion handler will invoked user click ok/cancel
    [panel beginWithCompletionHandler:^(NSInteger result)
    {
         //only need to handle 'ok'
         if(NSFileHandlingPanelOKButton == result)
         {
             //alloc
             serializedRules = [NSMutableDictionary dictionary];
    
             //sync to access
             @synchronized(self.rules)
             {
                 //iterate over all rules
                 // ->serialize & add each
                 for(Rule* rule in self.rules)
                 {
                     //covert/add
                     serializedRules[rule.path] = [rule serialize];
                 }
             }
            
             //save serialized rules to disk
             // on error will show err msg in popup
             if(YES != [serializedRules writeToURL:[panel URL] atomically:YES])
             {
                 //err msg
                 logMsg(LOG_DEBUG, [NSString stringWithFormat:@"failed to export rules to %@", panel.URL.path]);
                 
                 //init alert
                 alert = [[NSAlert alloc] init];
                 
                 //set style
                 alert.alertStyle = NSAlertStyleWarning;
                 
                 //main text
                 [alert setMessageText:@"ERROR: failed to save rules"];
                 
                 //details
                 [alert setInformativeText:[NSString stringWithFormat:@"path: %@", panel.URL.path]];
                 
                 //add button
                 [alert addButtonWithTitle:@"Ok"];
                 
                 //show
                 [alert runModal];
                 
             }
             
             //happy
             // update status message
             else
             {
                 //update msg
                 self.rulesStatusMsg.stringValue = @"exported rules";
            }
             
         }//clicked 'ok' (to save)
        
        //remove msg shortly thereafter
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            
            //update msg
            self.rulesStatusMsg.stringValue = @"";
            
        });
        
     }]; //panel callback
    
    return;
}

//delete a rule
// grab rule, then invoke daemon to delete
-(IBAction)deleteRule:(id)sender
{
    //index of row
    // either clicked or selected row
    NSInteger row = 0;
    
    //rule
    __block Rule* rule = nil;
    
    //sender nil?
    // invoked manually due to context menu
    if(nil == sender)
    {
        //get clicked row
        row = self.tableView.clickedRow;
    }
    //invoked via button click
    // grab selected row to get index
    else
    {
        //get selected row
        row = [self.tableView rowForView:sender];
    }

    //get rule
    rule = [self ruleForRow:row];
    if(nil == rule)
    {
        //bail
        goto bail;
    }
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"deleting rule for %@", rule.path]);
    
    //remove rule via XPC
    [self.daemonComms deleteRule:rule.path];
    
bail:
    
    return;
}

//button handler for 'add rules'
// show 'add rule' sheet and then, on close, add rule via XPC
-(IBAction)addRule:(id)sender
{
    //process path
    __block NSString* processPath = nil;
    
    //binary path
    // when user specified app
    __block NSString* binaryPath = nil;
    
    //action
    __block NSUInteger action = 0;
    
    //flag for conflicting rules
    __block BOOL conflictingRule = NO;
    
    //alert
    __block NSAlert* alert = nil;
    
    //alloc sheet
    self.addRuleWindowController = [[AddRuleWindowController alloc] initWithWindowNibName:@"AddRule"];
    
    //show it
    // on close/OK, invoke XPC to add rule, then reload
    [self.window beginSheet:self.addRuleWindowController.window completionHandler:^(NSModalResponse returnCode) {
        
        //on OK, add rule via XPC
        if(returnCode == NSModalResponseOK)
        {
            //get process path
            processPath = self.addRuleWindowController.processPath.stringValue;
            
            //when it's an app
            // ->get path to app's binary
            if(YES == [processPath hasSuffix:@".app"])
            {
                //get path
                binaryPath = getAppBinary(processPath);
                if(nil != binaryPath)
                {
                    //assign
                    processPath = binaryPath;
                }
            }
            
            //get action
            action = self.addRuleWindowController.action;
            
            //sync
            //  and then check for conflicts
            @synchronized(self.rules)
            {
                //any conflict w/ existing rule?
                for(Rule* rule in self.rules)
                {
                    //check
                    if(YES == [rule.path isEqualToString:processPath])
                    {
                        //set flag
                        conflictingRule = YES;
                        
                        //init alert
                        alert = [[NSAlert alloc] init];
                        
                        //set style
                        alert.alertStyle = NSAlertStyleWarning;
                        
                        //main text
                        [alert setMessageText:@"ERROR: failed to add rule"];
                        
                        //details
                        [alert setInformativeText:[NSString stringWithFormat:@"a rule for %@ already exists", processPath]];
                        
                        //add button
                        [alert addButtonWithTitle:@"Ok"];
                        
                        //show
                        [alert runModal];
                        
                        //done
                        break;
                        
                    }
                }
            }
            
            //add rule
            // but only if there were no conflicts
            if(YES != conflictingRule)
            {
                //dbg msg
                logMsg(LOG_DEBUG, [NSString stringWithFormat:@"adding rule for %@, action: %lu", processPath, action]);
                
                //add rule via XPC
                [self.daemonComms addRule:processPath action:action];
                
                //show new rule
                self.toolbar.selectedItemIdentifier = @"user";
            }
            
        } //NSModalResponseOK

        //unset add rule window controller
        self.addRuleWindowController = nil;
        
    }];
    
    return;
}

//listen for rule changes
// invoke daemon method, then block
-(void)listenForRuleChanges
{
    //daemon comms object
    DaemonComms* daemon = nil;
    
    //wait semaphore
    dispatch_semaphore_t semaphore = 0;
    
    //init daemon
    // use local var here, as we need to block
    daemon = [[DaemonComms alloc] init];

    //init sema
    semaphore = dispatch_semaphore_create(0);
    
    //ask for changes
    // call daemon and block, then display, and repeat!
    while(YES)
    {
        //pool
        @autoreleasepool
        {
        
        //dbg msg
        logMsg(LOG_DEBUG, @"requesting rules from daemon, will block");
        
        //wait for response from daemon via XPC
        [daemon getRules:YES reply:^(NSDictionary* daemonRules)
        {
             //dbg msg
             logMsg(LOG_DEBUG, [NSString stringWithFormat:@"got updated rules from daemon: %@", daemonRules]);
             
             //process new rules and refresh table
             dispatch_async(dispatch_get_main_queue(), ^{
                 
                 //process rules
                 [self processRulesDictionary:daemonRules];
                 
                 //(re)filter rules
                 [self filterRules];
                 
                 //reload table
                 [self.tableView reloadData];
                 
                 //select first row
                 [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
                 
             });
             
             //signal sema
             dispatch_semaphore_signal(semaphore);
             
         }];
        
        //wait for resposne, before to asking again
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
            
        }//pool
    }
    
    return;
}

//process rules dictionary received from daemon
// convert each rule dictionary into a Rule object
-(void)processRulesDictionary:(NSDictionary*)daemonRules
{
    //rule obj
    Rule* rule = nil;
    
    //sync
    @synchronized(self.rules)
    {
        //reset rules
        [self.rules removeAllObjects];
        
        //reset filtered rules
        [self.rulesFiltered removeAllObjects];
        
        //create rule objects
        // ->then add to array of rules
        for(NSString* processPath in daemonRules.allKeys)
        {
            //create rule
            rule = [[Rule alloc] init:processPath rule:daemonRules[processPath]];
            
            //add
            [self.rules addObject:rule];
        }
        
        //sort
        // case insensitive, by name
        [self.rules sortUsingDescriptors:[NSArray arrayWithObject:[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]]];
    }
    
    return;
}

//automatically invoked when user enters text in 'search' box
// ->filter tasks and/or items
-(void)controlTextDidChange:(NSNotification *)aNotification
{
    //filter
    [self filterRules];
    
    //reload table
    [self.tableView reloadData];
    
    return;
}

//init array of filtered rules
// determines what toolbar item is selected, then sort based on that and also what's in search box!
-(void)filterRules
{
    //selected toolbar item
    NSToolbarItem* selectedItem = nil;
    
    //dbg msg
    logMsg(LOG_DEBUG, @"filtering rules...");
    
    //find selected toolbar item
    for(NSToolbarItem* toolbarItem in self.toolbar.items)
    {
        //find
        if(YES == [toolbarItem.itemIdentifier isEqualToString:self.toolbar.selectedItemIdentifier])
        {
            //found match
            selectedItem = toolbarItem;
            
            //all done
            break;
        }
    }
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"selected toolbar item: %@/%@/%lu", selectedItem, selectedItem.itemIdentifier, selectedItem.tag]);
    
    //filter
    // unless user clicked 'all' and search box is blank
    @synchronized(self.rules)
    {
        //remove any previous
        [self.rulesFiltered removeAllObjects];
        
        //don't need to filter when user clicks 'all' & no search
        if( (-1 == selectedItem.tag) &&
            (0 == self.searchBox.stringValue.length) )
        {
            //unset flag
            self.shouldFilter = NO;
            
            //bail
            goto bail;
        }
        
        //set flag
        self.shouldFilter = YES;
        
        //dbg msg
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"filtering on '%@'", self.searchBox.stringValue]);
        
        //add any rule that matches
        for(Rule* rule in self.rules)
        {
            //'show all' rules
            // must match search
            if(-1 == selectedItem.tag)
            {
                //search
                // rule has to match
                if( (YES == [rule.name containsString:self.searchBox.stringValue]) ||
                    (YES == [rule.path containsString:self.searchBox.stringValue]) )
                {
                    //add
                    [self.rulesFiltered addObject:rule];
                }
            }
            
            //not 'show all'
            // gotta match filter, and if search, that too
            else if(selectedItem.tag == rule.type.intValue)
            {
                //no search?
                // just add rule
                if(0 == self.searchBox.stringValue.length)
                {
                    //add
                    [self.rulesFiltered addObject:rule];
                }
                
                //search
                // rule has to match
                else if( (YES == [rule.name containsString:self.searchBox.stringValue]) ||
                         (YES == [rule.path containsString:self.searchBox.stringValue]) )
                {
                    //add
                    [self.rulesFiltered addObject:rule];
                }
            }
        }
        
    }//sync
    
bail:
    
    //dbg msg
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"filtered rules: %@", self.rulesFiltered]);
    
    return;
}


#pragma mark -
#pragma mark table delegate methods

//number of rows
-(NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    //count
    NSInteger count = 0;
    
    //sync
    @synchronized(self.rules)
    {
        //filtered?
        if(YES == self.shouldFilter)
        {
            //set count
            count = self.rulesFiltered.count;
        }
        
        //not filtered?
        else
        {
            //set count
            count = self.rules.count;
        }
        
    }//sync
    
    return count;
}

//cell for table column
-(NSView*)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    //cell
    NSTableCellView *tableCell = nil;
    
    //rule obj
    Rule* rule = nil;
    
    //process name
    NSString* processName = nil;
    
    //process path
    NSString* processPath = nil;
    
    //process icon
    NSImage* processIcon = nil;
    
    //get rule
    rule = [self ruleForRow:row];
    if(nil == rule)
    {
        //bail
        goto bail;
    }
    
    //column: 'process'
    // set process icon, name and path
    if(tableColumn == tableView.tableColumns[0])
    {
        //set process path
        processPath = rule.path;
        
        //set process name
        processName = rule.name;
        
        //set icon
        processIcon = getIconForProcess(processPath);
        
        //init table cell
        tableCell = [tableView makeViewWithIdentifier:@"processCell" owner:self];
        if(nil == tableCell)
        {
            //bail
            goto bail;
        }
        
        //set icon
        tableCell.imageView.image = processIcon;
        
        //set (main) text
        // process name (device)
        tableCell.textField.stringValue = processName;
        
        //set sub text
        [[tableCell viewWithTag:TABLE_ROW_SUB_TEXT_TAG] setStringValue:processPath];
        
        //set detailed text color to gray
        ((NSTextField*)[tableCell viewWithTag:TABLE_ROW_SUB_TEXT_TAG]).textColor = [NSColor grayColor];
    }
    
    //column: 'type'
    // set rule type
    else if(tableColumn == tableView.tableColumns[1])
    {
        //init table cell
        tableCell = [tableView makeViewWithIdentifier:@"typeCell" owner:self];
        if(nil == tableCell)
        {
            //bail
            goto bail;
        }
        
        switch(rule.type.intValue)
        {
            //rule type: 'default'
            case RULE_TYPE_DEFAULT:
                
                //set text
                tableCell.textField.stringValue = @"default";
                
                break;
                
            //rule type: 'apple'
            case RULE_TYPE_APPLE:
                
                //set text
                tableCell.textField.stringValue = @"apple";
                
                break;
                
            //rule type: 'baseline'
            case RULE_TYPE_BASELINE:
                
                //set text
                tableCell.textField.stringValue = @"baseline";
                
                break;
            
            //rule type: 'user'
            case RULE_TYPE_USER:
                
                //set text
                tableCell.textField.stringValue = @"user";
                
                break;
                
            default:
                break;
        }
    
    }//column: 'type'
    
    //column: 'rule'
    // set icon and rule action
    else
    {
        //init table cell
        tableCell = [tableView makeViewWithIdentifier:@"ruleCell" owner:self];
        if(nil == tableCell)
        {
            //bail
            goto bail;
        }
        
        //block
        if(RULE_STATE_BLOCK == rule.action.integerValue)
        {
            //set image
            tableCell.imageView.image = [NSImage imageNamed:@"block"];
            
            //set text
            tableCell.textField.stringValue = @"block";
        }
        
        //allow
        else
        {
            //set image
            tableCell.imageView.image = [NSImage imageNamed:@"allow"];
            
            //set text
            tableCell.textField.stringValue = @"allow";
        }
        
        //disable button delete button if rule is a default (system) rule
        if(RULE_TYPE_DEFAULT == rule.type.intValue)
        {
            //disable
            [(NSButton*)[tableCell viewWithTag:TABLE_ROW_DELETE_TAG] setEnabled:NO];
        }
        
        //otherwise
        // enable delete button
        else
        {
            //enable
            [(NSButton*)[tableCell viewWithTag:TABLE_ROW_DELETE_TAG] setEnabled:YES];
        }
    }
    
bail:
    
    return tableCell;
}

//row for view
-(NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row
{
    //row view
    RuleRow* rowView = nil;
    
    //row ID
    static NSString* const kRowIdentifier = @"RowView";
    
    //try grab existing row view
    rowView = [tableView makeViewWithIdentifier:kRowIdentifier owner:self];
    
    //make new if needed
    if(nil == rowView)
    {
        //create new
        // ->size doesn't matter
        rowView = [[RuleRow alloc] initWithFrame:NSZeroRect];
        
        //set row ID
        rowView.identifier = kRowIdentifier;
    }
    
    return rowView;
}

//given a table row
// find/return the corresponding rule
-(Rule*)ruleForRow:(NSInteger)row
{
    //rule
    Rule* rule = nil;
    
    //sanity check
    if(-1 == row)
    {
        //bail
        goto bail;
    }
    
    //sync
    @synchronized(self.rules)
    {
    
    //get rule from filtered
    if(YES == self.shouldFilter)
    {
        //sanity check
        if(row >= self.rulesFiltered.count)
        {
            //bail
            goto bail;
        }
        
        //get rule
        rule = self.rulesFiltered[row];
    }
    
    //get rule from all
    else
    {
        //sanity check
        if(row >= self.rules.count)
        {
            //bail
            goto bail;
        }
        
        //get rule
        rule = self.rules[row];
    }
        
    }//sync
    
bail:
    
    return rule;
}

//invoke before showing menu
// customize with toggle action
-(void)menuNeedsUpdate:(NSMenu *)menu
{
    //rule
    Rule* rule = nil;
    
    //get rule
    rule = [self ruleForRow:self.tableView.selectedRow];
    if(nil == rule)
    {
        //error
        // disable menu
        toggleMenu(menu, NO);
        
        //bail
        goto bail;
    }
    
    //disable menu for default (system) rules
    // these should not be edited via normal users!
    if(RULE_TYPE_DEFAULT == rule.type)
    {
        //disable menu
        toggleMenu(menu, NO);
        
        //bail
        goto bail;
    }
    
    //allow?
    // show 'block' to toggle
    if(RULE_STATE_ALLOW == rule.action.integerValue)
    {
        //set title
        menu.itemArray.firstObject.title = @"toggle (block)";
        
        //set tag
        menu.itemArray.firstObject.tag = MENU_ITEM_BLOCK;
    }
    
    //block
    // show 'allow' to toggle
    else
    {
        //set title
        menu.itemArray.firstObject.title = @"toggle (allow)";
        
        //set tag
        menu.itemArray.firstObject.tag = MENU_ITEM_ALLOW;
    }
    
    //enable
    toggleMenu(menu, YES);
    
bail:
 
    return;
}


//menu handler for row context menu
-(IBAction)rowMenuHandler:(id)sender
{
    //rule
    Rule* rule = nil;
    
    //get rule
    rule = [self ruleForRow:self.tableView.selectedRow];
    if(nil == rule)
    {
        //err msg
        logMsg(LOG_ERR, @"failed to find rule for row");
        
        //bail
        goto bail;
    }
    
    //handle click
    switch(((NSMenuItem*)sender).tag)
    {
        //block rule
        case MENU_ITEM_BLOCK:
            
            //dbg msg
            logMsg(LOG_DEBUG, @"updating rule: block");
            
            //update with 'block'
            [self.daemonComms updateRule:rule.path action:RULE_STATE_BLOCK];
            
            break;
            
        //allow rule
        case MENU_ITEM_ALLOW:
            
            //dbg msg
            logMsg(LOG_DEBUG, @"updating rule: allow");
            
            //update with 'allow'
            [self.daemonComms updateRule:rule.path action:RULE_STATE_ALLOW];
            
            break;
        
        //delete rule
        case MENU_ITEM_DELETE:
            
            //delete
            [self deleteRule:nil];
            
            break;
            
        default:
            
            break;
    }
    
bail:
    
    return;
}
@end
